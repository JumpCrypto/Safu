// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface SafuLike {
    // Record that white-hat has deposited funds.
    function deposit(address erc20, uint256 wad) external;

    // all eligible bounties for msg.sender are transfered
    function withdraw() external;
}

contract SimpleSafu {
    struct Deposit {
        IERC20 token 

    }

    address[] public depositors;
    mapping(address => )
}

/*
pro rata with cap per token
mapping : token -> cap
mapping : token -> percentOfDepositWithdrawable

depositor delay

sender
    - deposits
    - waits x time
    - sender can withdraw share after delay
    
each deposit keyed by (sender addr, blocktime)

*/