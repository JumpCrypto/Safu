// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface ISafu {
    // Record that white-hat has deposited funds.
    function deposit(address erc20, uint256 wad) external returns (uint64);

    // Claims all of sender's eligible bounties.
    function claim() external;

    // Bounty amount and approval status for a given deposit id
    function bounty(uint64 id) external returns (uint256 amt, bool approved);

    // Query bounty cap for token
    function getBountyCapForToken(address token) external returns (uint256);

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

    // Increase the bounty cap for specified token. Bounty caps can only go up
    function increaseBountyCapForToken(address token, uint256 increase)
        external
        returns (uint256);

    // Prevent new deposits. Useful when migrating to a new contract to prevent accidental deposits
    function disableDeposits() external;
}
