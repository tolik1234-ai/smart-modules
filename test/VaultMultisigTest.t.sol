// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {VaultMultisig} from "../src/VaultMultisig/VaultMultisig.sol";
import {AccessManager} from "../src/AccessManager/AccessManager.sol";

contract VaultMultisigTest is Test {
    VaultMultisig vault;
    AccessManager accessManager;
    uint256 quorum = 2;
    address[] signers;

    address signer1 = vm.addr(1);
    address signer2 = vm.addr(2);
    address signer3 = vm.addr(3);
    address defaultRecipient = vm.addr(999);
    address stranger = vm.addr(777);

    function setUp() public {
        signers.push(signer1);
        signers.push(signer2);
        signers.push(signer3);

        accessManager = new AccessManager();
        vault = new VaultMultisig(signers, quorum, address(accessManager));
    }

    // =====================Test Functions=====================
    function test_ExecuteTransferRevertIfNoEtherOnVault(address _randomAddress) public {
        vm.assume(_randomAddress != address(0));

        vm.prank(signer1);
        vault.initiateTransfer(_randomAddress, 1 wei);

        vm.prank(signer2);
        vault.approveTransfer(0);

        console.log("Vault Balance:", address(vault).balance);

        vm.prank(signer1);
        vm.expectRevert(abi.encodeWithSelector(VaultMultisig.InsufficientBalance.selector, 0, 1 wei));
        vault.executeTransfer(0);
    }

    function test_InitiateTransferRevertIfInvalidRecipient() public {
        address recipient = address(0);

        vm.prank(signer1);

        vm.expectRevert(VaultMultisig.InvalidRecipient.selector);

        vault.initiateTransfer(recipient, 1 wei);
    }

    function test_InitiateTransferRevertInvalidAmount(address _randomAddress) public {
        vm.assume(_randomAddress != address(0));

        vm.prank(signer1);

        vm.expectRevert(VaultMultisig.InvalidAmount.selector);

        vault.initiateTransfer(_randomAddress, 0);
    }

    function test_InitiateTransferShouldWork(address _randomAddress) public {
        vm.assume(_randomAddress != address(0));
        fundVault(1 ether);

        vm.prank(signer1);
        vm.expectEmit(true, true, false, true);
        emit VaultMultisig.TransferInitiated(0, _randomAddress, 1 ether);

        vault.initiateTransfer(_randomAddress, 1 ether);

        (address to, uint256 amount, uint256 approvals, bool executed) = vault.getTransfer(0);

        assertEq(to, _randomAddress);
        assertEq(amount, 1 ether);
        assertEq(approvals, 1);
        assertFalse(executed);
    }

    function test_approveTransferShouldWork() public {
        fundVault(1 ether);

        vm.prank(signer1);
        vault.initiateTransfer(defaultRecipient, 1 ether);

        vm.prank(signer2);
        vault.approveTransfer(0);

        vm.prank(signer3);
        vault.approveTransfer(0);

        (address to, uint256 amount, uint256 approvals, bool executed) = vault.getTransfer(0);

        assertEq(to, defaultRecipient);
        assertEq(amount, 1 ether);
        assertEq(approvals, 3);
        assertFalse(executed);
    }

    function test_approveTransferRevertSignerAlreadyApproved() public {
        fundVault(1 ether);

        vm.startPrank(signer1); // <----- while (to override nide to use new startPrank)
        vault.initiateTransfer(defaultRecipient, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(VaultMultisig.SignerAlreadyApproved.selector, signer1));
        vault.approveTransfer(0);
    }

    function test_approveTransferShouldEmitTransferApprove() public {
        fundVault(1 ether);

        vm.prank(signer1);
        vault.initiateTransfer(defaultRecipient, 1 ether);

        vm.prank(signer2);
        vm.expectEmit(false, false, false, true);
        emit VaultMultisig.TransferApproved(0, signer2);
        vault.approveTransfer(0);
    }

    function test_executeTransferRevertQuorumHasNotBeenReached() public {
        fundVault(1 ether);

        vm.startPrank(signer1);
        vault.initiateTransfer(defaultRecipient, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(VaultMultisig.QuorumHasNotBeenReached.selector, 0));
        vault.executeTransfer(0);
    }

    function test_onlyMultisigSignerWorks() public {
        fundVault(1 ether);

        vm.prank(signer1);
        vault.initiateTransfer(defaultRecipient, 1 ether);

        vm.prank(stranger);
        vm.expectRevert(VaultMultisig.InvalidMultisigSigner.selector);
        vault.executeTransfer(0);
    }

    function test_executeTransferRevertTransferAlreadyExecuted() public {
        fundVault(1 ether);

        vm.prank(signer1);
        vault.initiateTransfer(defaultRecipient, 1 ether);

        vm.prank(signer2);
        vault.approveTransfer(0);

        vm.prank(signer3);
        vault.executeTransfer(0);

        vm.prank(signer1);
        vm.expectRevert(abi.encodeWithSelector(VaultMultisig.TransferIsAlreadyExecuted.selector, 0));
        vault.executeTransfer(0);
    }

    function test_executeTransferShouldWorkAndEmitTransferExecuted() public {
        fundVault(1 ether);

        vm.prank(signer1);
        vault.initiateTransfer(defaultRecipient, 1 ether);

        vm.prank(signer2);
        vault.approveTransfer(0);

        vm.prank(signer3);
        vm.expectEmit(false, false, false, true);
        emit VaultMultisig.TransferExecuted(0);
        vault.executeTransfer(0);

        (address to, uint256 amount, uint256 approvals, bool executed) = vault.getTransfer(0);
        assertEq(to, defaultRecipient);
        assertEq(amount, 1 ether);
        assertEq(approvals, 2);
        assertTrue(executed);
    }

    function test_hasSignedTransferShouldWork() public {
        fundVault(1 ether);

        vm.prank(signer1);
        vault.initiateTransfer(defaultRecipient, 1 ether);

        bool signed1 = vault.hasSignedTransfer(0, signer1);
        assertTrue(signed1);

        bool signed2 = vault.hasSignedTransfer(0, signer2);
        assertFalse(signed2);
    }

    function test_getTransferCountWorks() public {
        fundVault(10 ether);

        for (uint256 i; i < 10; i++) {
            vm.prank(signer1);
            vault.initiateTransfer(defaultRecipient, 1 ether);

            uint256 transferCount = vault.getTransferCount();
            assertEq(transferCount - 1, i);

            console.log(transferCount);
        }
    }

    function test_constructorRevertSignersArrayCannotBeEmpty() public {
        address[] memory empty;

        vm.expectRevert(VaultMultisig.SignersArrayCannotBeEmpty.selector);
        new VaultMultisig(empty, quorum, address(accessManager));
    }

    function test_constructorRevertQuorumGreaterThanSigners() public {
        vm.expectRevert(VaultMultisig.QuorumGreaterThanSigners.selector);
        new VaultMultisig(signers, 4, address(accessManager));
    }

    function test_constructorRevertQuorumCannotBeZero() public {
        vm.expectRevert(VaultMultisig.QuorumCannotBeZero.selector);
        new VaultMultisig(signers, 0, address(accessManager));
    }

    // =====================Internal Functions=====================
    function fundVault(uint256 _amount) internal {
        vm.deal(address(vault), _amount);
    }
}
