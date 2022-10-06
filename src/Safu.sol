// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC20/IERC20.sol";

interface SafuLike {
    // Record that white-hat has deposited funds.
    function deposit(address erc20, uint256 wad) external returns (uint64);

    // Claims all of sender's eligible bounties.
    function claim() external;

    // Bounty amount and approval status for a given deposit id
    function bounty(uint64 id) external returns (uint256 amt, bool approved);

    /*****************************/
    /* Authority only operations */
    /*****************************/

    // Withdraw deposited funds to authority for given token
    function withdrawToken(address token) external returns (uint256);

    // Withdraw funds for all tokens
    function withdraw() external;

    // Approve bounty for deposit id
    function approveBounty(uint64 id) external;

    // Deny bounty for deposit id
    function denyBounty(uint64 id) external;
}

contract Safu is SafuLike {
    struct Receipt {
        // Deposit id
        uint64 id;
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
        uint256 approved;
        uint256 claimed;
        uint64[] receiptIds;
    }

    address[] public tokens;
    mapping(uint64 => Receipt) public idToReceipt;
    mapping(address => uint64[]) public depositorToReceipts;
    mapping(address => TokenInfo) public tokenInfos;

    // To enable multi-sig or governance, have that wallet be the
    // authority indirectly
    address public authority;
    uint64 nextId = 0;
    // Default maximum sum of all bounties paid out for a given token.
    uint256 public immutable defaultBountyCap;
    // Minimum elapsed time before deposit can be claimed.
    // This gives a window after an incident for all potential depositors to
    // deposit and get a pro-rata portion of bounty cap
    uint256 public immutable minDelay;
    // After this elapsed time, the authority may withdraw the entire deposit.
    // This prevents funds being permanently locked within the contract
    // if the depositor never claims the bounty.
    uint256 public immutable maxDelay;
    // Time from deposit that the authority may deny the deposit. If
    // after this time the deposit is automatically approved.
    uint256 public immutable denialWindow;
    // Percent of the deposit eligible to be claimed by depositor if approved.
    // If the sum of approved bounties is greater than the bountyCap, the actual
    // claimable bounty is fairly shared amoung depositors, which will be less
    // than bountyPercent.
    uint8 public immutable bountyPercent;

    // Flag must be true for depositors to claim rewards
    bool public rewardsClaimable;
    // If true, deposits automatically approved with no action necessary by authority
    bool public autoApprove;

    event Deposit(address indexed depositor, Receipt receipt);
    event Claim(address indexed depositor, Receipt receipt, uint256 bounty);
    event Withdraw(address indexed token, uint256 bounty);

    constructor(
        uint256 _defaultBountyCap,
        uint256 _minDelay,
        uint256 _maxDelay,
        uint256 _denialWindow,
        uint8 _bountyPercent,
        bool _rewardsClaimable,
        bool _autoApprove,
        address _authority
    ) {
        defaultBountyCap = _defaultBountyCap;
        minDelay = _minDelay;
        denialWindow = _denialWindow;
        maxDelay = _maxDelay;
        bountyPercent = _bountyPercent;
        rewardsClaimable = _rewardsClaimable;
        autoApprove = _autoApprove;
        authority = _authority;
    }

    function withdraw() public {
        require(msg.sender == authority, "Safu/authority-only-op");
        for (uint256 i = 0; i < tokens.length; ++i) {
            withdrawToken(tokens[i]);
        }
    }

    function withdrawToken(address token) public returns (uint256) {
        require(msg.sender == authority, "Safu/authority-only-op");
        TokenInfo storage tokenInfo = tokenInfos[token];
        uint256 withdrawable = tokenInfo.closedReceiptsToWithdraw;
        for (uint256 i = 0; i < tokenInfo.receiptIds.length; ++i) {
            Receipt storage receipt = idToReceipt[tokenInfo.receiptIds[i]];
            if (receipt.depositBlockTime + maxDelay <= block.timestamp) {
                uint256 toWithdraw = receipt.deposited -
                    receipt.authorityWithdrawn;
                withdrawable += toWithdraw;
                receipt.authorityWithdrawn += toWithdraw;
            } else if (receipt.isApproved) {
                uint256 toWithdraw = receipt.deposited -
                    receipt.bounty -
                    receipt.authorityWithdrawn;
                withdrawable += toWithdraw;
                receipt.authorityWithdrawn += toWithdraw;
            }
        }

        IERC20(token).transfer(authority, withdrawable);
        emit Withdraw(token, withdrawable);
        return withdrawable;
    }

    function approveBounty(uint64 id) external {
        require(msg.sender == authority, "Safu/only-authority-can-approve");
        Receipt memory receipt = getReceipt(id);
        receipt.isApproved = true;
        tokenInfos[receipt.token].approved += receipt.bounty;
        setReceipt(receipt);
    }

    // Deny bounty deletes receipt and
    // allow remaining un-withdrawn deposit to be withdrawn
    function denyBounty(uint64 id) external {
        require(msg.sender == authority, "Safu/only-authority-can-approve");
        Receipt memory receipt = idToReceipt[id];
        require(
            !receipt.isApproved &&
                block.timestamp < receipt.depositBlockTime + denialWindow,
            "Safu/cannot-deny-approved-receipt"
        );
        tokenInfos[receipt.token].closedReceiptsToWithdraw +=
            receipt.deposited -
            receipt.authorityWithdrawn;
        deleteReceipt(id);
    }

    // Claims all of sender's eligible bounties.
    function claim() external {
        if (!rewardsClaimable) {
            return;
        }
        uint64[] storage receipts = depositorToReceipts[msg.sender];
        uint64[] memory toDelete = new uint64[](receipts.length);
        uint256 deleteIdx = 0;
        for (uint256 i = 0; i < receipts.length; ++i) {
            Receipt memory receipt = idToReceipt[receipts[i]];
            if (
                (receipt.isApproved ||
                    block.timestamp >
                    receipt.depositBlockTime + denialWindow) &&
                receipt.depositBlockTime + minDelay <= block.timestamp
            ) {
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
                // do not delete entry during loop
                toDelete[deleteIdx++] = receipt.id;
            }
        }
        for (uint256 i = 0; i < deleteIdx; ++i) {
            deleteReceipt(toDelete[i]);
        }
    }

    function deposit(address erc20, uint256 wad) external returns (uint64) {
        require(wad > 0, "Safu/zero-deposit");
        IERC20(erc20).transferFrom(msg.sender, address(this), wad);

        Receipt memory receipt = Receipt(
            nextId++,
            erc20,
            wad,
            (wad * bountyPercent) / 100,
            0,
            block.timestamp,
            autoApprove
        );
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
        uint256 cap = getTokenToBountyCap(receipt.token);
        // todo: decide if this should write the result to the receipt.
        // downside is bounty would no longer be 'view,' so less useful for clients
        // upside is more consistent/accurate receipt.isApproved field
        // => lean against writing
        bool isApproved = receipt.isApproved ||
            block.timestamp > receipt.depositBlockTime + denialWindow;
        if (cap == 0) {
            return (0, isApproved);
        }
        require(
            tokenInfo.approved >= tokenInfo.claimed,
            "Safu/approvals-must-be-greater-than-claims"
        );
        if (tokenInfo.approved <= cap) {
            // enough bounty to go around, so pay out in full
            return (receipt.bounty, isApproved);
        }
        /*
         * claimed <= approved < cap
         * cap < approved
         * => claimed < approved since claimed <= cap
         * => totalClaimable > 0
         */
        uint256 totalClaimable = tokenInfo.approved - tokenInfo.claimed;
        uint256 capRemaining = cap - tokenInfo.claimed;
        // not enough bounty to fully pay all receipts, so scale bounty fairly
        uint256 ratio = (capRemaining * 1000) / totalClaimable;
        uint256 share = (receipt.bounty * ratio) / 1000;
        return (share, isApproved);
    }

    function bounty(uint64 id) external view returns (uint256, bool) {
        return bounty(getReceipt(id));
    }

    function getReceipt(uint64 id) public view returns (Receipt memory) {
        Receipt memory receipt = idToReceipt[id];
        require(
            receipt.token != address(0),
            "Safu/deposit-not-found-for-id-address-pair"
        );
        return receipt;
    }

    function deleteReceipt(uint64 id) internal {
        address token = idToReceipt[id].token;
        delete idToReceipt[id];
        for (uint256 i = 0; i < tokenInfos[token].receiptIds.length; ++i) {
            if (tokenInfos[token].receiptIds[i] == id) {
                delete tokenInfos[token].receiptIds[i];
                return;
            }
        }
    }

    function createReceipt(address depositor, Receipt memory receipt) internal {
        idToReceipt[receipt.id] = receipt;
        tokenInfos[receipt.token].receiptIds.push(receipt.id);
        depositorToReceipts[depositor].push(receipt.id);
    }

    function setReceipt(Receipt memory receipt) internal {
        idToReceipt[receipt.id] = receipt;
    }

    function getTokenToBountyCap(address token) public view returns (uint256) {
        uint256 cap = tokenInfos[token].bountyCap;
        if (cap == 0) {
            return defaultBountyCap;
        }
        return cap;
    }

    function changeAuthority(address newAuthority) public {
        require(
            msg.sender == authority,
            "Safu/only-existing-authority-can-change-authority"
        );
        authority = newAuthority;
    }

    function setRewardsClaimable(bool _rewardsClaimable) public {
        require(msg.sender == authority, "Safu/authority-only-op");
        rewardsClaimable = _rewardsClaimable;
    }

    function setAutoApprove(bool _autoApprove) public {
        require(msg.sender == authority, "Safu/authority-only-op");
        autoApprove = _autoApprove;
    }

    function setBountyCapForToken(address token, uint256 cap) public {
        require(msg.sender == authority, "Safu/authority-only-op");
        tokenInfos[token].bountyCap = cap;
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
}
