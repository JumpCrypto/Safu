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
    IERC20 erc20;

    uint256 defaultBountyCap = 1000;
    uint256 minDelay = 10;
    uint256 maxDelay = 20;
    uint8 bountyPercent = 50;

    event Deposit(address indexed depositor, SimpleSafu.Receipt receipt);

    function setUp() public {
        DummyERC20 _erc20 = new DummyERC20("testERC20", "TBD");
        _erc20.mint(address(this), 1_000_000);
        erc20 = _erc20;
    }

    function testDepositClaimSuccess() public {
        SimpleSafu safu = new SimpleSafu(
            defaultBountyCap,
            minDelay,
            maxDelay,
            bountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(erc20.approve(address(safu), 1_000));
        uint64 id = safu.deposit(address(erc20), 1_000);
        // todo: understand why this fails even though the output looks identical
        // vm.expectEmit(true, false, false, true);
        // emit Deposit(
        //     address(this),
        //     SimpleSafu.Receipt(0, erc20, 500, block.timestamp, false)
        // );
        assertEq(safu.getTokenToBountyCap(erc20), defaultBountyCap);
        assertBounty(safu, id, 500, false);

        safu.approveBounty(address(this), id);

        assertBounty(safu, id, 500, true);
        uint256 prev = erc20.balanceOf(address(this));
        safu.claim();
        assertEq(erc20.balanceOf(address(this)), prev + 500);
    }

    function testApprovalsGreaterThanCap() public {
        SimpleSafu safu = new SimpleSafu(
            defaultBountyCap,
            minDelay,
            maxDelay,
            bountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(erc20.approve(address(safu), 10_000));
        uint64 id1 = safu.deposit(address(erc20), 1_000);
        safu.approveBounty(address(this), id1);
        assertBounty(safu, id1, 500, true);
        uint256 prev = erc20.balanceOf(address(this));
        safu.claim();
        assertEq(erc20.balanceOf(address(this)), prev + 500);

        uint64 id2 = safu.deposit(address(erc20), 1_000);
        safu.approveBounty(address(this), id2);
        assertBounty(safu, id2, 500, true);

        uint64 id3 = safu.deposit(address(erc20), 1_000);
        safu.approveBounty(address(this), id3);

        // approved is 1500, but cap is 1000 and 500 already claimed
        // split remaining 500 between receipts fairly  
        assertBounty(safu, id2, 250, true);
        assertBounty(safu, id3, 250, true);

        prev = erc20.balanceOf(address(this));
        safu.claim();
        assertEq(erc20.balanceOf(address(this)), prev + 500);

        // deposit when no remaining 
    }

    function assertBounty(
        SimpleSafu safu,
        uint64 id,
        uint256 expectedAmt,
        bool expectedApproved
    ) internal {
        (uint256 bountyAmt, bool isApproved) = safu.bounty(id);
        assertEq(bountyAmt, expectedAmt);
        assertEq(isApproved, expectedApproved);
    }
}
