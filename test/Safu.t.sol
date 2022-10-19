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
    address randomUser = 0xD0c986905BaD5FA05127cddC53A4aA9048e32f50;
    uint256 defaultBountyCap = 1000;
    uint256 defaultMinDelay = 0;
    uint256 defaultMaxDelay = 20;
    uint8 defaultBountyPercent = 50;

    event Deposit(address indexed depositor, Safu.Receipt receipt);

    function setUp() public {
        DummyERC20 _erc20 = new DummyERC20("testERC20", "TBD");
        _erc20.mint(address(this), 1_000_000);
        _erc20.mint(randomUser, 1_000_000);
        erc20 = address(_erc20);
    }

    function testDepositClaimSuccess() public {
        Safu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        assertTrue(IERC20(erc20).approve(address(safu), 1_000));
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
        uint64 id = safu.deposit(erc20, 1_000);
        assertEq(safu.getBountyCapForToken(erc20), defaultBountyCap);
        assertBounty(safu, id, 500, false);

        safu.approveBounty(id);

        assertBounty(safu, id, 500, true);
        uint256 prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);
    }

    function testApprovalsGreaterThanCap() public {
        ISafu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
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

        vm.prank(randomUser);
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        vm.prank(randomUser);
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
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 125);

        prev = IERC20(erc20).balanceOf(randomUser);
        vm.prank(randomUser);
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(randomUser), prev + 375);
    }

    function testNoCapacityLeft() public {
        ISafu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
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
        ISafu safu = new Safu(
            minDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
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

    function testMaxDelay() public {
        ISafu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 2_000);
        assertBounty(safu, id, 1000, false);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        vm.warp(block.timestamp + defaultMaxDelay);

        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 2000);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 2000);
    }

    function testApproveIdempotent() public {
        Safu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        assertTrue(IERC20(erc20).approve(address(safu), 1_000));
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
        uint64 id = safu.deposit(erc20, 1_000);
        assertEq(safu.getBountyCapForToken(erc20), defaultBountyCap);
        assertBounty(safu, id, 500, false);

        safu.approveBounty(id);
        assertBounty(safu, id, 500, true);

        safu.approveBounty(id);
        assertBounty(safu, id, 500, true);

        vm.prank(randomUser);
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        vm.prank(randomUser);
        uint64 id2 = safu.deposit(erc20, 1_000);
        safu.approveBounty(id2);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);
        assertEq(safu.withdrawToken(erc20), 1000);
    }

    function testWithdraw() public {
        uint256 minDelay = 5;
        ISafu safu = new Safu(
            minDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 1_000);

        // cannot withdraw before approval
        uint256 prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        safu.approveBounty(id);

        // cannot withdraw until after minDelay
        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        vm.warp(block.timestamp + minDelay);

        // now can withdraw
        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 500);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);

        // no double withdraw
        prev = IERC20(erc20).balanceOf(address(this));
        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        // second deposit
        id = safu.deposit(erc20, 2_000);

        safu.denyBounty(id);

        // no warp needed to withdraw denied bounty
        prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 2000);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 2000);
    }

    function testMultipleWithdraw() public {
        ISafu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 1_000);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 0);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 0);

        safu.approveBounty(id);

        assertBounty(safu, id, 500, true);

        safu.claim();
        assertEq(safu.withdrawToken(erc20), 500);
        assertEq(safu.withdrawToken(erc20), 0);
    }

    function testWithdrawAfterClaim() public {
        ISafu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
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

    function testClaimAfterWithdraw() public {
        ISafu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        uint64 id = safu.deposit(erc20, 1_000);

        safu.approveBounty(id);

        assertBounty(safu, id, 500, true);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        assertEq(safu.withdrawToken(erc20), 500);
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);

        prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);
    }

    function testAutoApprove() public {
        Safu safu = new Safu(5, defaultMaxDelay, defaultBountyPercent, true);

        assertTrue(IERC20(erc20).approve(address(safu), 1_000));
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
        uint64 id = safu.deposit(erc20, 1_000);
        assertEq(safu.getBountyCapForToken(erc20), defaultBountyCap);
        assertBounty(safu, id, 500, true);

        assertEq(safu.getTokenInfo(erc20).approved, 500);

        uint256 prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev);

        vm.warp(block.timestamp + 5);

        prev = IERC20(erc20).balanceOf(address(this));
        safu.claim();
        assertEq(IERC20(erc20).balanceOf(address(this)), prev + 500);
    }

    function testShutdown() public {
        ISafu safu = new Safu(
            defaultMinDelay,
            defaultMaxDelay,
            defaultBountyPercent,
            false
        );
        safu.increaseBountyCapForToken(erc20, defaultBountyCap);
        assertTrue(IERC20(erc20).approve(address(safu), 10_000));
        safu.shutdown();

        vm.expectRevert();
        safu.deposit(erc20, 1_000);
    }

    function assertBounty(
        ISafu safu,
        uint64 id,
        uint256 expectedAmt,
        bool expectedApproved
    ) internal {
        (uint256 bountyAmt, bool isApproved) = safu.bounty(id);
        assertEq(bountyAmt, expectedAmt);
        assertEq(isApproved, expectedApproved);
    }
}
