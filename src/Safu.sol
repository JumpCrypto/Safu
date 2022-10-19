// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./ISafu.sol";

import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/access/Ownable.sol";

contract Safu is ISafu, Ownable {
    struct Receipt {
        // Deposit id
        uint64 id;
        // Address of user who deposited
        address depositor;
        // Token deposited
        address token;
        // Amount of token deposited
        uint256 deposited;
        // Amount claimable by depositor after approval
        uint256 bounty;
        // Amount withdrawn by authority
        uint256 authorityWithdrawn;
        // Block time deposit occured at
        uint256 depositBlockTime;
        // Approval status
        bool isApproved;
    }

    struct TokenInfo {
        uint256 closedReceiptsToWithdraw;
        uint256 bountyCap;
        // Value of realized claims + maximum value of unrealized claims.
        // Can decrease if a full bounty is not paid out when approved is greater than cap
        uint256 approved;
        // Value of realized claims
        uint256 claimed;
        // Receipt ids for this token
        uint64[] receiptIds;
    }

    address[] public tokens;
    mapping(uint64 => Receipt) public idToReceipt;
    mapping(address => uint64[]) public depositorToReceipts;
    mapping(address => TokenInfo) public tokenInfos;

    uint64 nextId = 0;
    // Minimum elapsed time before deposit can be claimed.
    // This gives a window after an incident for all potential depositors to
    // deposit and get a pro-rata portion of bounty cap
    uint256 public immutable minDelay;
    // After this elapsed time, the authority may withdraw the entire deposit.
    // This prevents funds being permanently locked within the contract
    // if the depositor never claims the bounty.
    uint256 public immutable maxDelay;
    // Percent of the deposit eligible to be claimed by depositor if approved.
    // If the sum of approved bounties is greater than the bountyCap, the actual
    // claimable bounty is fairly shared amoung depositors, which will be less
    // than bountyPercent.
    uint8 public immutable bountyPercent;

    // If true, deposits automatically approved with no action necessary by authority
    bool public autoApprove;
    // If true, prevents new deposits. Cannot be undone
    bool public areDepositsDisabled;

    event Deposit(address indexed depositor, Receipt receipt);
    event Claim(address indexed depositor, Receipt receipt, uint256 bounty);
    event Withdraw(address indexed token, uint256 bounty);

    constructor(
        uint256 _minDelay,
        uint256 _maxDelay,
        uint8 _bountyPercent,
        bool _autoApprove
    ) {
        minDelay = _minDelay;
        maxDelay = _maxDelay;
        bountyPercent = _bountyPercent;
        autoApprove = _autoApprove;
        require(_minDelay <= _maxDelay, "Safu/min-delay-leq-max-delay");
        require(
            _bountyPercent >= 0 && _bountyPercent <= 100,
            "Safu/bounty-percent-must-be-in-range[0,100]"
        );
    }

    function withdraw() external onlyOwner {
        for (uint256 i = 0; i < tokens.length; ++i) {
            withdrawToken(tokens[i]);
        }
    }

    function withdrawToken(address token) public onlyOwner returns (uint256) {
        TokenInfo storage tokenInfo = tokenInfos[token];

        uint256 withdrawable = tokenInfo.closedReceiptsToWithdraw;
        tokenInfo.closedReceiptsToWithdraw = 0;

        for (uint256 i = 0; i < tokenInfo.receiptIds.length; ++i) {
            Receipt storage receipt = idToReceipt[tokenInfo.receiptIds[i]];
            if (receipt.depositBlockTime + maxDelay <= block.timestamp) {
                // withdraw all if after max delay
                uint256 toWithdraw = receipt.deposited -
                    receipt.authorityWithdrawn;
                withdrawable += toWithdraw;
                receipt.authorityWithdrawn += toWithdraw;
            } else if (
                receipt.isApproved &&
                receipt.depositBlockTime + minDelay <= block.timestamp
            ) {
                // withdraw all but bounty if approved and after min delay
                uint256 toWithdraw = receipt.deposited -
                    receipt.bounty -
                    receipt.authorityWithdrawn;
                withdrawable += toWithdraw;
                receipt.authorityWithdrawn += toWithdraw;
            }
        }

        if (withdrawable > 0) {
            IERC20(token).transfer(owner(), withdrawable);
            emit Withdraw(token, withdrawable);
        }
        return withdrawable;
    }

    function approveBounty(uint64 id) external onlyOwner {
        Receipt storage receipt = idToReceipt[id];
        require(
            receipt.token != address(0),
            "Safu/deposit-not-found-for-id-address-pair"
        );
        if (receipt.isApproved) {
            return;
        }
        receipt.isApproved = true;
        tokenInfos[receipt.token].approved += receipt.bounty;
    }

    // Deny bounty deletes receipt and
    // allow remaining un-withdrawn deposit to be withdrawn
    function denyBounty(uint64 id) external onlyOwner {
        Receipt memory receipt = idToReceipt[id];
        require(
            receipt.token != address(0),
            "Safu/deposit-not-found-for-id-address-pair"
        );
        require(!receipt.isApproved, "Safu/cannot-deny-approved-receipt");
        tokenInfos[receipt.token].closedReceiptsToWithdraw +=
            receipt.deposited -
            receipt.authorityWithdrawn;
        deleteReceipt(id);
    }

    event Log(uint256);

    // Claims all of sender's eligible bounties.
    function claim() external {
        // Keep this as "memory" to avoid modifications caused by deleting receipts in loop
        uint64[] memory receipts = depositorToReceipts[msg.sender];
        for (uint256 i = 0; i < receipts.length; ++i) {
            emit Log(receipts.length);
            claim(receipts[i]);
        }
    }

    // Attempts to claim a given receipt id, returns amount claimed or 0 if not claimable at this time
    function claim(uint64 id) public returns (uint256) {
        Receipt memory receipt = idToReceipt[id];
        if (
            !receipt.isApproved ||
            receipt.depositBlockTime + minDelay > block.timestamp
        ) {
            return 0;
        }
        TokenInfo storage tokenInfo = tokenInfos[receipt.token];
        (uint256 bountyAmt, ) = bounty(receipt);
        emit Claim(msg.sender, receipt, bountyAmt);
        IERC20(receipt.token).transfer(msg.sender, bountyAmt);
        tokenInfo.claimed += bountyAmt;
        // if claimed amount is less than approved bountyAmt,
        // adjust outstanding approvals
        tokenInfo.approved -= receipt.bounty - bountyAmt;
        // ensure no funds get trapped in contract
        tokenInfo.closedReceiptsToWithdraw +=
            receipt.deposited -
            receipt.authorityWithdrawn -
            bountyAmt;

        deleteReceipt(id);

        return bountyAmt;
    }

    function deposit(address erc20, uint256 wad)
        external
        notDepositsDisabled
        returns (uint64)
    {
        require(wad > 0, "Safu/zero-deposit");
        IERC20(erc20).transferFrom(msg.sender, address(this), wad);

        Receipt memory receipt = Receipt(
            nextId++,
            msg.sender,
            erc20,
            wad,
            (wad * bountyPercent) / 100,
            0,
            block.timestamp,
            autoApprove
        );
        if (autoApprove) {
            tokenInfos[receipt.token].approved += receipt.bounty;
        }

        emit Deposit(msg.sender, receipt);
        createReceipt(msg.sender, receipt);
        return receipt.id;
    }

    function bounty(Receipt memory receipt)
        internal
        view
        returns (uint256, bool)
    {
        TokenInfo memory tokenInfo = tokenInfos[receipt.token];
        uint256 cap = getBountyCapForToken(receipt.token);
        if (cap == 0) {
            return (0, receipt.isApproved);
        }
        require(
            tokenInfo.approved >= tokenInfo.claimed,
            "Safu/approvals-must-always-be-greater-than-claims"
        );
        if (tokenInfo.approved <= cap) {
            // enough bounty to go around, so pay out in full
            return (receipt.bounty, receipt.isApproved);
        }
        // Note the definition of approved in the tokenInfo struct. If approvals are greater than the cap with multiple parties, each party gets a pro-rata share of the remaining bounty cap
        // *unaffected* by the ordering of claims
        uint256 totalClaimable = tokenInfo.approved - tokenInfo.claimed;
        uint256 capRemaining = cap - tokenInfo.claimed;
        // not enough bounty to fully pay all receipts, so scale bounty fairly
        /*
         * claimed <= approved and claimed <= cap (generally true)
         * cap < approved (bc if statement)
         * => claimed < approved => totalClaimable > 0 => ratio defined
         */
        uint256 ratio = (capRemaining * 1000) / totalClaimable;
        uint256 share = (receipt.bounty * ratio) / 1000;
        return (share, receipt.isApproved);
    }

    function bounty(uint64 id) external view returns (uint256, bool) {
        Receipt memory receipt = idToReceipt[id];
        require(
            receipt.token != address(0),
            "Safu/deposit-not-found-for-id-address-pair"
        );
        return bounty(receipt);
    }

    function getReceipt(uint64 id) external view returns (Receipt memory) {
        Receipt memory receipt = idToReceipt[id];
        require(
            receipt.token != address(0),
            "Safu/deposit-not-found-for-id-address-pair"
        );
        return receipt;
    }

    function deleteReceipt(uint64 id) internal {
        address token = idToReceipt[id].token;
        address depositor = idToReceipt[id].depositor;
        delete idToReceipt[id];
        uint64[] storage tokenReceipts = tokenInfos[token].receiptIds;
        for (uint256 i = 0; i < tokenReceipts.length; ++i) {
            if (tokenReceipts[i] == id) {
                tokenReceipts[i] = tokenReceipts[tokenReceipts.length - 1];
                tokenReceipts.pop();
                break;
            }
        }
        uint64[] storage depostorReceipts = depositorToReceipts[depositor];
        for (uint256 i = 0; i < depostorReceipts.length; ++i) {
            if (depostorReceipts[i] == id) {
                depostorReceipts[i] = depostorReceipts[depostorReceipts.length - 1];
                depostorReceipts.pop();
                break;
            }
        }
    }

    function createReceipt(address depositor, Receipt memory receipt) internal {
        idToReceipt[receipt.id] = receipt;
        tokenInfos[receipt.token].receiptIds.push(receipt.id);
        depositorToReceipts[depositor].push(receipt.id);
        // ensure tokens list has token
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] == receipt.token) {
                return;
            }
        }
        tokens.push(receipt.token);
    }

    function getBountyCapForToken(address token) public view returns (uint256) {
        return tokenInfos[token].bountyCap;
    }

    function getTokenInfo(address token)
        public
        view
        returns (TokenInfo memory)
    {
        return tokenInfos[token];
    }

    function setAutoApprove(bool _autoApprove) public onlyOwner {
        autoApprove = _autoApprove;
    }

    function increaseBountyCapForToken(address token, uint256 increase)
        public
        onlyOwner
        returns (uint256)
    {
        tokenInfos[token].bountyCap += increase;
        // cap is multiplied by 1000 when calculating bounty, ensure it does not overflow
        require(
            tokenInfos[token].bountyCap * 1000 > increase,
            "Safu/bounty-cap-times-1000-doesnt-overflow"
        );
        return tokenInfos[token].bountyCap;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > b) {
            return a;
        }
        return b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > b) {
            return b;
        }
        return a;
    }

    modifier notDepositsDisabled() {
        require(!areDepositsDisabled, "Safu/contract-shudown");
        _;
    }

    function disableDeposits() external onlyOwner {
        areDepositsDisabled = true;
    }
}
