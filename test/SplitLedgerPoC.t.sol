// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReceiptSplitVault, ReceiptBoundVault, MockAsset} from "../src/ReceiptSplitVault.sol";

/// Directed PoC: 100 in, 200 out. Local Foundry only.
contract SplitLedgerPoC is Test {
    MockAsset internal asset;
    ReceiptSplitVault internal vault;
    address internal attacker = address(0xA11CE);
    address internal victim = address(0xBEEF);

    function setUp() public {
        asset = new MockAsset();
        vault = new ReceiptSplitVault(asset);
        asset.mint(attacker, 100 ether);
        asset.mint(victim, 100 ether);
        vm.startPrank(victim);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100 ether);
        vm.stopPrank();
        vm.startPrank(attacker);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100 ether);
        vm.stopPrank();
    }

    function test_double_pay_via_split_ledgers() public {
        // Burns ledger A then ledger B. Victim's 100 is the second payment.
        vm.startPrank(attacker);
        vault.withdrawShares(100 ether);
        vault.redeemReceipt(1);
        vm.stopPrank();

        assertEq(asset.balanceOf(attacker), 200 ether, "attacker deposited 100 and extracted 200");
        assertEq(asset.balanceOf(address(vault)), 0, "victim residue stolen");
        assertEq(vault.shares(victim), 100 ether, "victim share still recorded, backing gone");
    }

    function test_bound_vault_blocks_double_pay() public {
        ReceiptBoundVault bound = new ReceiptBoundVault(asset);
        vm.startPrank(attacker);
        asset.mint(attacker, 100 ether);
        asset.approve(address(bound), type(uint256).max);
        uint256 id = bound.deposit(100 ether);
        bound.redeemReceipt(id);
        vm.expectRevert(bytes("SPENT"));
        bound.redeemReceipt(id);
        vm.stopPrank();
        assertEq(asset.balanceOf(address(bound)), 0);
        assertEq(bound.shares(attacker), 0);
        assertEq(bound.totalOpen(), 0);
        assertEq(bound.openClaims(), 0);
    }

    /// Both doors stay. The share exit pays 40. The receipt then pays 60, not
    /// the original 100. The other depositor is untouched.
    function test_bound_share_exit_then_receipt_pays_only_the_rest() public {
        ReceiptBoundVault bound = new ReceiptBoundVault(asset);
        asset.mint(attacker, 100 ether);
        asset.mint(victim, 100 ether);

        vm.startPrank(attacker);
        asset.approve(address(bound), type(uint256).max);
        uint256 attackerId = bound.deposit(100 ether);
        vm.stopPrank();
        vm.startPrank(victim);
        asset.approve(address(bound), type(uint256).max);
        uint256 victimId = bound.deposit(100 ether);
        vm.stopPrank();

        vm.startPrank(attacker);
        bound.withdrawShares(40 ether);
        bound.redeemReceipt(attackerId);
        vm.expectRevert(bytes("SPENT"));
        bound.redeemReceipt(attackerId);
        vm.expectRevert(bytes("SHARES"));
        bound.withdrawShares(1);
        vm.stopPrank();

        assertEq(asset.balanceOf(attacker), 100 ether, "attacker deposited 100 and got 100 back");
        assertEq(bound.shares(attacker), 0);
        assertEq(asset.balanceOf(address(bound)), 100 ether, "victim backing still there");

        vm.prank(victim);
        bound.redeemReceipt(victimId);
        assertEq(asset.balanceOf(victim), 100 ether);
        assertEq(asset.balanceOf(address(bound)), 0);
        assertEq(bound.openClaims(), 0);
    }

    /// 30 + 70 deposited. A 40 share withdrawal closes the first receipt and
    /// 10 of the second. The receipt door then pays the remaining 60.
    function test_bound_share_exit_spans_two_receipts() public {
        ReceiptBoundVault bound = new ReceiptBoundVault(asset);
        asset.mint(attacker, 100 ether);
        vm.startPrank(attacker);
        asset.approve(address(bound), type(uint256).max);
        uint256 first = bound.deposit(30 ether);
        uint256 second = bound.deposit(70 ether);
        bound.withdrawShares(40 ether);
        (, uint256 firstAmount, uint256 firstPaid) = bound.receipts(first);
        (, uint256 secondAmount, uint256 secondPaid) = bound.receipts(second);
        assertEq(firstPaid, firstAmount);
        assertEq(secondPaid, 10 ether);
        assertEq(secondAmount - secondPaid, 60 ether);
        bound.redeemReceipt(second);
        vm.expectRevert(bytes("SPENT"));
        bound.redeemReceipt(first);
        vm.stopPrank();
        assertEq(asset.balanceOf(attacker), 100 ether);
        assertEq(bound.totalOpen(), bound.openClaims());
        assertEq(bound.totalOpen(), 0);
    }

    function test_zero_deposit_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("ZERO"));
        vault.deposit(0);
    }

    function test_withdraw_more_than_shares_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("SHARES"));
        vault.withdrawShares(100 ether + 1);
    }

    function test_redeem_wrong_owner_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("OWNER"));
        vault.redeemReceipt(0); // receipt 0 belongs to victim
    }

    function test_redeem_unknown_id_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("ID"));
        vault.redeemReceipt(99);
    }
}
