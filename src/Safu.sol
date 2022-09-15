// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC20/IERC20.sol";

interface SafuLike {
    // Record that white-hat has deposited funds.
    function deposit(address erc20, uint256 wad) external;

    // all eligible bounties for msg.sender are transfered
    function claim() external;

    function bounty(uint16 id) external returns (uint256 amt, bool approved);

    function approveBounty(uint16 id) external;
}

contract SimpleSafu {
    struct Receipt {
        uint16 id;
        IERC20 token;
        uint256 amt;
        uint256 blockTime;
        bool rewardApproved;
    }

    address[] public depositors;
    mapping(address => Receipt[]) depositorToReceipts;
    mapping(IERC20 => uint256) public tokenToBountyCap;
    mapping(IERC20 => uint256) public tokenToTotalDeposited;
    mapping(IERC20 => uint256) public tokenToBountyWithdrawn;
    uint256 public immutable defaultBountyCap;
    uint256 public immutable minDelay;
    uint256 public immutable maxDelay;
    uint8 public immutable bountyPercent;

    bool public rewardsClaimable;
    bool public autoApprove;

    constructor(
        uint256 _defaultBountyCap,
        uint256 _minDelay,
        uint256 _maxDelay,
        uint8 _bountyPercent,
        bool _rewardsClaimable,
        bool _autoApprove
    ) {
        defaultBountyCap = _defaultBountyCap;
        minDelay = _minDelay;
        maxDelay = _maxDelay;
        bountyPercent = _bountyPercent;
        rewardsClaimable = _rewardsClaimable;
        autoApprove = _autoApprove;
    }

    function deposit(address _erc20, uint256 wad) external {
        require(wad > 0, "Safu/zero-deposit");
        depositors.push(msg.sender);
        IERC20 erc20 = IERC20(_erc20);

        uint256 prevTotalBounty = tokenToTotalDeposited[erc20] -
            tokenToBountyWithdrawn[erc20];
        // if (prevTotalBounty + )
    }

    function bounty(address guy, uint16 id) public view returns (uint256 amt, bool approved) { 
        Receipt memory receipt = getReceipt(guy, id);
        approved = receipt.rewardApproved;
        if ()
    }

    function bounty(uint16 id) public view returns (uint256 amt, bool approved) {
        return bounty(msg.sender, id);
    }

    function getReceipt(address depositor, uint16 id)
        public
        view
        returns (Receipt memory)
    {
        Receipt[] storage deposits = depositorToReceipts[depositor];
        for (uint256 i = 0; i < deposits.length; ++i) {
            if (deposits[i].id == id) {
                return deposits[i];
            }
        }
        revert("Safu/deposit-not-found-for-id-address-pair");
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

*/
