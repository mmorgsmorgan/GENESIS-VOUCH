// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GenesisVouch.sol";

contract GenesisVouchTest is Test {
    GenesisVouch gv;

    address platform = address(0xF1a7);

    // backers
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCEA0);

    // members (subjects only — no wallets)
    uint16 constant M1 = 1;
    uint16 constant M2 = 2;
    uint16 constant M3 = 3;

    uint256 constant FEE = 2500; // 25%
    // Tests drive vm.warp in seconds, so the round length here is the Solidity `7 days` literal.
    // On Ritual (ms clock) the deploy passes 604_800_000 instead — see test_msRoundDuration.
    uint256 constant DUR = 7 days;

    function setUp() public {
        gv = new GenesisVouch(platform, 988, FEE, DUR);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    function _endRound() internal {
        vm.warp(block.timestamp + gv.roundDuration());
    }

    // ---------------------------------------------------------------- //
    //  vouch + running leader
    // ---------------------------------------------------------------- //
    function test_vouch_tracksLeader() public {
        vm.prank(alice);
        gv.vouch{value: 10 ether}(M1);
        (,,,, uint16 leaderId, uint256 leaderTotal) = gv.currentRound();
        assertEq(leaderId, M1);
        assertEq(leaderTotal, 10 ether);

        vm.prank(bob);
        gv.vouch{value: 25 ether}(M2);
        (,,,, leaderId, leaderTotal) = gv.currentRound();
        assertEq(leaderId, M2);
        assertEq(leaderTotal, 25 ether);

        vm.prank(carol);
        gv.vouch{value: 20 ether}(M1); // M1 -> 30, overtakes
        (,,,, leaderId, leaderTotal) = gv.currentRound();
        assertEq(leaderId, M1);
        assertEq(leaderTotal, 30 ether);
    }

    function test_tie_firstToReachHolds() public {
        vm.prank(alice);
        gv.vouch{value: 10 ether}(M1);
        vm.prank(bob);
        gv.vouch{value: 10 ether}(M2); // equal — strict > keeps M1
        (,,,, uint16 leaderId,) = gv.currentRound();
        assertEq(leaderId, M1);
    }

    function test_vouch_belowMin_reverts() public {
        vm.prank(alice);
        vm.expectRevert(GenesisVouch.BelowMinVouch.selector);
        gv.vouch{value: 0.0001 ether}(M1);
    }

    function test_vouch_badMember_reverts() public {
        vm.prank(alice);
        vm.expectRevert(GenesisVouch.BadMember.selector);
        gv.vouch{value: 1 ether}(0);
        vm.prank(alice);
        vm.expectRevert(GenesisVouch.BadMember.selector);
        gv.vouch{value: 1 ether}(989);
    }

    function test_vouch_afterRoundOver_reverts() public {
        _endRound();
        vm.prank(alice);
        vm.expectRevert(GenesisVouch.RoundOver.selector);
        gv.vouch{value: 1 ether}(M1);
    }

    // ---------------------------------------------------------------- //
    //  settle math: platform 25%, backers 75% of P + 100% of losers
    // ---------------------------------------------------------------- //
    function test_settle_splitAndClaims() public {
        // Winner M1 pool = 100 (alice 40, carol 60). Losers: M2 = 60 (bob).
        vm.prank(alice);
        gv.vouch{value: 40 ether}(M1);
        vm.prank(carol);
        gv.vouch{value: 60 ether}(M1);
        vm.prank(bob);
        gv.vouch{value: 60 ether}(M2);

        _endRound();

        uint256 platBefore = platform.balance;
        gv.settle();

        // platform paid 25 of P(=100)
        assertEq(platform.balance - platBefore, 25 ether, "platform 25%");

        GenesisVouch.Round memory rd = gv.getRound(1);
        assertEq(rd.winnerId, M1);
        assertEq(rd.winnerPool, 100 ether);
        // backerPot = 75 (rest of P) + 60 losers = 135
        assertEq(rd.backerPot, 135 ether, "backer pot");
        assertEq(gv.roundId(), 2, "round advanced");

        // alice 40/100 * 135 = 54 ; carol 60/100 * 135 = 81
        uint256 aBefore = alice.balance;
        vm.prank(alice);
        gv.claimBackerReward(1);
        assertEq(alice.balance - aBefore, 54 ether, "alice reward");

        uint256 cBefore = carol.balance;
        vm.prank(carol);
        gv.claimBackerReward(1);
        assertEq(carol.balance - cBefore, 81 ether, "carol reward");

        // bob backed a loser -> nothing
        vm.prank(bob);
        vm.expectRevert(GenesisVouch.NothingToClaim.selector);
        gv.claimBackerReward(1);

        // contract fully drained for round 1 (25 + 54 + 81 = 160 = total staked)
        assertEq(address(gv).balance, 0, "contract drained");
    }

    function test_doubleClaim_reverts() public {
        vm.prank(alice);
        gv.vouch{value: 40 ether}(M1);
        vm.prank(bob);
        gv.vouch{value: 10 ether}(M2);
        _endRound();
        gv.settle();
        vm.prank(alice);
        gv.claimBackerReward(1);
        vm.prank(alice);
        vm.expectRevert(GenesisVouch.AlreadyClaimed.selector);
        gv.claimBackerReward(1);
    }

    function test_soleBackerTakesWholePot() public {
        // M1 wins with 100 (alice only). Loser M2 = 60. No member payout at all.
        vm.prank(alice);
        gv.vouch{value: 100 ether}(M1);
        vm.prank(bob);
        gv.vouch{value: 60 ether}(M2);
        _endRound();
        gv.settle();

        GenesisVouch.Round memory rd = gv.getRound(1);
        // backerPot = 75 + 60 = 135
        assertEq(rd.backerPot, 135 ether);
        uint256 aBefore = alice.balance;
        vm.prank(alice);
        gv.claimBackerReward(1);
        assertEq(alice.balance - aBefore, 135 ether, "alice takes whole pot");
    }

    // ---------------------------------------------------------------- //
    //  zero-stake round just rolls over
    // ---------------------------------------------------------------- //
    function test_settle_zeroStake_rollsOver() public {
        _endRound();
        gv.settle();
        assertEq(gv.roundId(), 2);
        GenesisVouch.Round memory rd = gv.getRound(1);
        assertTrue(rd.settled);
        assertEq(rd.backerPot, 0);
    }

    function test_settle_beforeEnd_reverts() public {
        vm.prank(alice);
        gv.vouch{value: 10 ether}(M1);
        vm.expectRevert(GenesisVouch.RoundNotOver.selector);
        gv.settle();
    }

    function test_settle_twice_reverts() public {
        _endRound();
        gv.settle();
        // round advanced; the new empty round hasn't ended -> RoundNotOver
        vm.expectRevert(GenesisVouch.RoundNotOver.selector);
        gv.settle();
    }

    // ---------------------------------------------------------------- //
    //  configurable fee
    // ---------------------------------------------------------------- //
    function test_feeConfigurable() public {
        gv.setPlatformFeeBps(1000); // 10%
        vm.prank(alice);
        gv.vouch{value: 100 ether}(M1);
        vm.prank(bob);
        gv.vouch{value: 40 ether}(M2);
        _endRound();
        uint256 pb = platform.balance;
        gv.settle();
        assertEq(platform.balance - pb, 10 ether, "10% fee");
        GenesisVouch.Round memory rd = gv.getRound(1);
        assertEq(rd.backerPot, 90 ether + 40 ether, "90 + losers");
    }

    function test_feeCap_reverts() public {
        vm.expectRevert(GenesisVouch.FeeTooHigh.selector);
        gv.setPlatformFeeBps(3001);
    }

    function test_ctorFeeCap_reverts() public {
        vm.expectRevert(GenesisVouch.FeeTooHigh.selector);
        new GenesisVouch(platform, 988, 3001, DUR);
    }

    function test_ctorZeroDuration_reverts() public {
        vm.expectRevert(GenesisVouch.BadDuration.selector);
        new GenesisVouch(platform, 988, FEE, 0);
    }

    // ---------------------------------------------------------------- //
    //  Ritual clocks block.timestamp in MILLISECONDS: a 7-day round must be
    //  604_800_000 units. This guards against regressing to the `7 days`
    //  (604_800) literal, which would settle in ~10 minutes on Ritual.
    // ---------------------------------------------------------------- //
    function test_msRoundDuration() public {
        uint256 sevenDaysMs = 604_800_000;
        GenesisVouch g = new GenesisVouch(platform, 988, FEE, sevenDaysMs);
        assertEq(g.roundDuration(), sevenDaysMs);

        // Simulate a ms-scale clock. Vouch is allowed right up to the boundary...
        vm.warp(1_700_000_000_000); // 13-digit ms timestamp, like Ritual
        g = new GenesisVouch(platform, 988, FEE, sevenDaysMs);
        (,, uint256 endsAt,,,) = g.currentRound();
        assertEq(endsAt, block.timestamp + sevenDaysMs, "endsAt is start + 7 days(ms)");

        vm.prank(alice);
        g.vouch{value: 5 ether}(M1);

        // ...one ms before the end it still settles-not-yet; after it, settle works.
        vm.warp(block.timestamp + sevenDaysMs - 1);
        vm.expectRevert(GenesisVouch.RoundNotOver.selector);
        g.settle();

        vm.warp(block.timestamp + 1); // now exactly at end
        g.settle();
        assertEq(g.roundId(), 2, "advanced after full ms round");
    }

    // ---------------------------------------------------------------- //
    //  views
    // ---------------------------------------------------------------- //
    function test_getActiveTotals() public {
        vm.prank(alice);
        gv.vouch{value: 10 ether}(M1);
        vm.prank(bob);
        gv.vouch{value: 5 ether}(M3);
        (uint16[] memory ids, uint256[] memory amts) = gv.getActiveTotals();
        assertEq(ids.length, 2);
        assertEq(ids[0], M1);
        assertEq(amts[0], 10 ether);
        assertEq(ids[1], M3);
        assertEq(amts[1], 5 ether);
    }

    function test_pendingBackerReward_view() public {
        vm.prank(alice);
        gv.vouch{value: 60 ether}(M1);
        vm.prank(bob);
        gv.vouch{value: 40 ether}(M2);
        _endRound();
        gv.settle();
        // M1 wins. P=60, backerPot = 45 (75% of 60) + 40 = 85, alice sole backer -> 85
        assertEq(gv.pendingBackerReward(1, alice), 85 ether);
        vm.prank(alice);
        gv.claimBackerReward(1);
        assertEq(gv.pendingBackerReward(1, alice), 0);
    }

    // ---------------------------------------------------------------- //
    //  reentrancy: malicious backer that re-enters on receive
    // ---------------------------------------------------------------- //
    function test_reentrancy_claimBlocked() public {
        Reenterer att = new Reenterer(gv);
        vm.deal(address(att), 100 ether);

        att.vouch{value: 50 ether}(M1); // attacker backs winner
        vm.prank(bob);
        gv.vouch{value: 10 ether}(M2);
        _endRound();
        gv.settle();

        uint256 balBefore = address(att).balance; // 50 ether (100 - 50 vouched)
        att.attack(1);
        // Only one claim of 47.5 succeeds; reentered call reverts.
        assertEq(address(att).balance, balBefore + 47.5 ether, "no double claim");
    }

    // admin
    function test_onlyOwner_setFee() public {
        vm.prank(alice);
        vm.expectRevert(GenesisVouch.NotOwner.selector);
        gv.setPlatformFeeBps(1000);
    }
}

/// @dev Attempts to re-enter claimBackerReward from its receive hook.
contract Reenterer {
    GenesisVouch public gv;
    uint256 public attackRound;
    bool private entered;

    constructor(GenesisVouch _gv) {
        gv = _gv;
    }

    function vouch(uint16 id) external payable {
        gv.vouch{value: msg.value}(id);
    }

    function attack(uint256 r) external {
        attackRound = r;
        gv.claimBackerReward(r);
    }

    receive() external payable {
        if (!entered) {
            entered = true;
            try gv.claimBackerReward(attackRound) {} catch {}
        }
    }
}
