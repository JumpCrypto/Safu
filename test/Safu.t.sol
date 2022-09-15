// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/ERC20.sol";
import "../src/Safu.sol";

contract DummyERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract SimpleSafuTest is Test {
    SimpleSafu safu;
    IERC20 erc20;

    function setUp() public {
        DummyERC20 _erc20 = new DummyERC20("testERC20", "TBD");
        _erc20.mint(address(this), 1_000_000);
        erc20 = _erc20;
    }

    function defaultSafu() SimpleSafu internal {
        uint256 defaultBountyCap = 10;
        uint256 minDelay = 10;
        uint256 maxDelay = 20;
        uint8 bountyPercent = 50;
        safu = new SimpleSafu(
            defaultBountyCap,
            minDelay,
            maxDelay,
            bountyPercent
        );
    }

    function testDepositSuccess() public {

        erc20.approve(address(this), 2_000);
        safu.deposit(address(erc20), 2_000);
        assertEq(safu.tokenToBountyCap(erc20), defaultBountyCap);
    }
}
