// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/utils/math/Math.sol";

interface SafuLike {
    // Record that white-hat has deposited funds.
    function deposit(address erc20, uint256 wad) external;

    // all eligible bounties for msg.sender are transfered
    function claim() external;

    function bounty(address guy, uint64 id)
        external
        returns (uint256 amt, bool approved);

    function bounty(uint64 id) external returns (uint256 amt, bool approved);

    function approveBounty(address guy, uint64 id) external;
}

contract SimpleSafu {
    struct Receipt {
        uint64 id;
        IERC20 token;
        uint256 amt;
        uint256 blockTime;
        bool rewardApproved;
    }

    // to enable multi-sig or governance, have that wallet be the authority indirectly
    address public authority;
    address[] public depositors;
    uint64 nextId = 0;
    mapping(address => Receipt[]) depositorToReceipts;
    mapping(IERC20 => uint256) private tokenToBountyCap;
    mapping(IERC20 => uint256) public tokenToTotalApproved;
    mapping(IERC20 => uint256) public tokenToTotalClaimed;
    uint256 public immutable defaultBountyCap;
    uint256 public immutable minDelay;
    uint256 public immutable maxDelay;
    uint8 public immutable bountyPercent;

    bool public rewardsClaimable;
    bool public autoApprove;

    event Deposit(address indexed depositor, Receipt receipt);
    event Claim(address indexed depositor, Receipt receipt, uint256 amt);

    constructor(
        uint256 _defaultBountyCap,
        uint256 _minDelay,
        uint256 _maxDelay,
        uint8 _bountyPercent,
        bool _rewardsClaimable,
        bool _autoApprove,
        address _authority
    ) {
        defaultBountyCap = _defaultBountyCap;
        minDelay = _minDelay;
        maxDelay = _maxDelay;
        bountyPercent = _bountyPercent;
        rewardsClaimable = _rewardsClaimable;
        autoApprove = _autoApprove;
        authority = _authority;
    }

    function approveBounty(address guy, uint64 id) external {
        require(msg.sender == authority, "Safu/only-authority-can-approve");
        Receipt memory receipt = getReceipt(guy, id);
        receipt.rewardApproved = true;
        tokenToTotalApproved[receipt.token] += receipt.amt;
        setReceipt(guy, receipt);
    }

    function claim() external {
        Receipt[] storage receipts = depositorToReceipts[msg.sender];
        uint256 deleteIdx = 0;
        uint256[] memory toDelete = new uint256[](100);
        for (uint256 i = 0; i < receipts.length; ++i) {
            (uint256 amt, bool approved) = bounty(receipts[i]);
            if (approved) {
                Receipt memory receipt = receipts[i];
                emit Claim(msg.sender, receipt, amt);
                receipt.token.transfer(msg.sender, amt);
                tokenToTotalClaimed[receipt.token] += amt;
                // if claimed amount is less than approved amt,
                // adjust outstanding approvals
                tokenToTotalApproved[receipt.token] -= receipt.amt - amt;
                // do not delete entry during loop
                toDelete[deleteIdx++] = i;
            }
        }
        for (uint256 i = 0; i < toDelete.length; ++i) {
            delete receipts[toDelete[i]];
        }
    }

    function deposit(address _erc20, uint256 wad) external returns (uint64) {
        require(wad > 0, "Safu/zero-deposit");
        depositors.push(msg.sender);
        IERC20 erc20 = IERC20(_erc20);
        erc20.transferFrom(msg.sender, address(this), wad);

        Receipt memory receipt = Receipt(
            nextId++,
            erc20,
            (wad * bountyPercent) / 100,
            block.timestamp,
            autoApprove
        );
        emit Deposit(msg.sender, receipt);
        setReceipt(msg.sender, receipt);
        return receipt.id;
    }

    function bounty(Receipt memory receipt)
        internal
        view
        returns (uint256 amt, bool approved)
    {
        uint256 totalApproved = tokenToTotalApproved[receipt.token];
        uint256 totalClaimed = tokenToTotalClaimed[receipt.token];
        uint256 cap = getTokenToBountyCap(receipt.token);
        if (cap == 0) {
            return (0, receipt.rewardApproved);
        }
        require(
            totalApproved >= totalClaimed,
            "Safu/approvals-must-be-greater-than-claims"
        );
        if (totalApproved <= cap) {
            // enough bounty to go around, so pay out in full
            return (receipt.amt, receipt.rewardApproved);
        }
        // claimed <= approved < cap
        // cap < approved
        // => claimed < approved since claimed <= cap
        // => totalClaimable > 0
        uint256 totalClaimable = totalApproved - totalClaimed;
        uint256 capRemaining = cap - totalClaimed;
        // not enough bounty to fully pay all receipts, so scale bounty fairly
        uint256 ratio = (capRemaining * 1000) / totalClaimable;
        uint256 share = (receipt.amt * ratio) / 1000;
        return (share, receipt.rewardApproved);
    }

    function bounty(address guy, uint64 id)
        public
        view
        returns (uint256 amt, bool approved)
    {
        Receipt memory receipt = getReceipt(guy, id);
        return bounty(receipt);
    }

    function bounty(uint64 id)
        external
        view
        returns (uint256 amt, bool approved)
    {
        return bounty(msg.sender, id);
    }

    function getReceipt(address depositor, uint64 id)
        public
        view
        returns (Receipt memory)
    {
        Receipt[] memory receipts = depositorToReceipts[depositor];
        for (uint256 i = 0; i < receipts.length; ++i) {
            if (receipts[i].id == id) {
                return receipts[i];
            }
        }
        revert("Safu/deposit-not-found-for-id-address-pair");
    }

    function setReceipt(address depositor, Receipt memory receipt) public {
        Receipt[] storage receipts = depositorToReceipts[depositor];
        for (uint256 i = 0; i < receipts.length; ++i) {
            if (receipts[i].id == receipt.id) {
                receipts[i] = receipt;
                return;
            }
        }
        receipts.push(receipt);
    }

    function getTokenToBountyCap(IERC20 token) public view returns (uint256) {
        uint256 cap = tokenToBountyCap[token];
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
}

/*
pro rata with cap per token
mapping : token -> cap
mapping : token -> percentOfReceiptWithdrawable

depositor delay

sender
    - deposits
    - waits x time
    - sender can withdraw share after delay
    
each deposit keyed by (sender addr, blocktime)

cap 500
claimed 100
approved 1100

deposit of 50: 
claimable: 1000
-> bounty is 25

cap 500
claimed 0
approved 1000
deposit of 50: 
claimable: 0
-> bounty is 25

cap 500
claimed 500
approved 1000
deposit of 50: 
claimable: 0
-> bounty is 25


*/
