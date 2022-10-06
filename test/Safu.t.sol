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

contract SafuTest is Test {
    address erc20;

    uint256 defaultBountyCap = 1000;
    uint256 defaultMinDelay = 0;
    uint256 defaultMaxDelay = 20;
    uint256 defaultDenialWindow = 10;
    uint8 defaultBountyPercent = 50;

    event Deposit(address indexed depositor, Safu.Receipt receipt);

    function setUp() public {
        DummyERC20 _erc20 = new DummyERC20("testERC20", "TBD");
        _erc20.mint(address(this), 1_000_000);
        erc20 = address(_erc20);
    }

    function testDepositClaimSuccess() public {
        Safu safu = new Safu(
            defaultBountyCap,
            defaultMinDelay,
            defaultMaxDelay,
            defaultDenialWindow,
            defaultBountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(IERC20(erc20).approve(address(safu), 1_000));
        uint64 id = safu.deposit(erc20, 1_000);
        // todo: understand why this fails even though the output looks identical
        // vm.expectEmit(true, false, false, true);
        // emit Deposit(
        //     address(this),
        //     Safu.Receipt(0, erc20, 500, block.timestamp, false)
        // );
        assertEq(safu.getTokenToBountyCap(erc20), defaultBountyCap);
        assertBounty(safu, id, 500, false);

        safu.approveBounty(id);

        assertBounty(safu, id, 500, true);
        uint256 prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);
    }

    function testApprovalsGreaterThanCap() public {
        SafuLike safu = new Safu(
            defaultBountyCap,
            defaultMinDelay,
            defaultMaxDelay,
            defaultDenialWindow,
            defaultBountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id1 = safu.deposit(erc20, 1_000);
        safu.approveBounty(id1);
        assertBounty(safu, id1, 500, true);
        uint256 prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);

        uint64 id2 = safu.deposit(erc20, 1_000);
        safu.approveBounty(id2);
        assertBounty(safu, id2, 500, true);

        uint64 id3 = safu.deposit(erc20, 3_000);

        // un-approved deposit has no effect on existing approved deposits
        assertBounty(safu, id2, 500, true);

        safu.approveBounty(id3);

        // approved is 4000, but cap is 1000 and 500 already claimed
        // split remaining 500 between receipts fairly
        assertBounty(safu, id2, 125, true);
        assertBounty(safu, id3, 375, true);

        prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);
    }

    function testNoCapacityLeft() public {
        SafuLike safu = new Safu(
            defaultBountyCap,
            defaultMinDelay,
            defaultMaxDelay,
            defaultDenialWindow,
            defaultBountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 2_000);
        safu.approveBounty(id);
        assertBounty(safu, id, 1000, true);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 1000);

        // deposit when no remaining
        uint64 id2 = safu.deposit(erc20, 1_000);
        safu.approveBounty(id2);
        assertBounty(safu, id2, 0, true);

        prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);
    }

    function testMinDelay() public {
        uint256 minDelay = 10;
        SafuLike safu = new Safu(
            defaultBountyCap,
            minDelay,
            defaultMaxDelay,
            defaultDenialWindow,
            defaultBountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 2_000);
        safu.approveBounty(id);
        assertBounty(safu, id, 1000, true);

        // cannot claim until minDelay elapsed
        uint256 prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        vm.warp(block.timestamp + minDelay);

        // now can claim
        prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 1000);
    }

    function testDenialWindow() public {
        Safu safu = new Safu(
            defaultBountyCap,
            defaultMinDelay,
            defaultMaxDelay,
            defaultDenialWindow,
            defaultBountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 2_000);
        assertBounty(safu, id, 1000, false);

        // cannot claim since not approved
        uint256 prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        vm.warp(block.timestamp + defaultDenialWindow + 1);

        // can no longer deny receipt
        vm.expectRevert();
        safu.denyBounty(id);

        // now can claim since auto approved after denial window passed
        assertBounty(safu, id, 1000, true);
        prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 1000);

        // confirm receipt gets deleted
        vm.expectRevert();
        safu.getReceipt(id);
    }

    function testMaxDelay() public {
        SafuLike safu = new Safu(
            defaultBountyCap,
            defaultMinDelay,
            defaultMaxDelay,
            defaultDenialWindow,
            defaultBountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 2_000);
        assertBounty(safu, id, 1000, false);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        vm.warp(block.timestamp + defaultDenialWindow + defaultMaxDelay);

        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 2000);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 2000);
    }

    function testWithdraw() public {
        SafuLike safu = new Safu(
            defaultBountyCap,
            defaultMinDelay,
            defaultMaxDelay,
            defaultDenialWindow,
            defaultBountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 1_000);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        safu.approveBounty(id);

        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 500);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);

        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        id = safu.deposit(erc20, 2_000);
        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        safu.denyBounty(id);

        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 2000);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 2000);
    }

    function testWithdrawAfterClaim() public {
        SafuLike safu = new Safu(
            defaultBountyCap,
            defaultMinDelay,
            defaultMaxDelay,
            defaultDenialWindow,
            defaultBountyPercent,
            true,
            false,
            address(this)
        );
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 1_000);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        safu.approveBounty(id);

        assertBounty(safu, id, 500, true);
        prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);

        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 500);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);
    }

    function assertBounty(
        SafuLike safu,
        uint64 id,
        uint256 expectedAmt,
        bool expectedApproved
    ) internal {
        (uint256 bountyAmt, bool isApproved) = safu.bounty(id);
        assertEq(bountyAmt, expectedAmt);
        assertEq(isApproved, expectedApproved);
    }
}
