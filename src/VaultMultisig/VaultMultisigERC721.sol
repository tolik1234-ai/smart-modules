// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract VaultMultisigERC721 {
    /// @notice The ERC721 token held and transferred by this vault
    IERC721 public token;

    /// @notice The number of signatures required to execute a transfer
    uint256 public quorum;

    /// @notice The total number of transfers ever initiated (also used as the next transfer ID)
    uint256 public transfersCount;

    /// @dev The struct is used to store the details of a transfer
    /// @param to The address of the recipient
    /// @param tokenId The ID of the NFT to transfer
    /// @param approvals The number of approvals collected so far
    /// @param executed Whether the transfer has been executed
    /// @param approved The mapping of signers to their approval status
    struct Transfer {
        address to;
        uint256 tokenId;
        uint256 approvals;
        bool executed;
        mapping(address => bool) approved;
    }

    /// @notice The mapping of transfer IDs to transfer details
    mapping(uint256 => Transfer) private transfers;

    /// @notice The mapping for verification that address is a signer
    mapping(address => bool) private multiSigSigners;

    /// @notice Thrown in the constructor when the signers array is empty
    error SignersArrayCannotBeEmpty();

    /// @notice Thrown in the constructor when the quorum exceeds the number of signers
    error QuorumGreaterThanSigners();

    /// @notice Thrown in the constructor when the quorum is zero
    error QuorumCannotBeZero();

    /// @notice Thrown in the constructor when a signer address is the zero address
    error InvalidSignerAddress();

    /// @notice Thrown in the constructor when the same address is listed as a signer more than once
    /// @param signer The address that was duplicated
    error DuplicateSigner(address signer);

    /// @notice Thrown when the recipient of a transfer is the zero address
    error InvalidRecipient();

    /// @notice Thrown when the caller is not a registered multisig signer
    error InvalidMultisigSigner();

    /// @notice Thrown when referencing a transfer ID that was never initiated
    /// @param transferId The ID of the transfer
    error TransferDoesNotExist(uint256 transferId);

    /// @notice Thrown when acting on a transfer that has already been executed
    /// @param transferId The ID of the transfer
    error TransferAlreadyExecuted(uint256 transferId);

    /// @notice Thrown when a signer tries to approve a transfer they already approved
    /// @param signer The address of the signer
    error SignerAlreadyApproved(address signer);

    /// @notice Thrown when trying to execute a transfer that has not collected enough approvals
    /// @param transferId The ID of the transfer
    error QuorumHasNotBeenReached(uint256 transferId);

    /// @notice Thrown when the vault does not currently own the requested NFT
    /// @param tokenId The ID of the NFT that is not held by the vault
    error TokenIsNotInWallet(uint256 tokenId);

    /// @notice Emitted when a new transfer is initiated
    event TransferInitiated(uint256 indexed transferId, address indexed to, uint256 tokenId);

    /// @notice Emitted when a signer approves a pending transfer
    event TransferApproved(uint256 transferId, address signer);

    /// @notice Emitted when a transfer is executed and the NFT is sent
    event TransferExecuted(uint256 transferId);

    /// @notice Restricts a function to addresses registered as multisig signers
    modifier onlyMultisigSigner() {
        if (!multiSigSigners[msg.sender]) revert InvalidMultisigSigner();
        _;
    }

    /// @notice Restricts a function to transfer IDs that were actually initiated
    /// @param _transferId The ID of the transfer to check
    modifier transferExists(uint256 _transferId) {
        if (_transferId >= transfersCount) revert TransferDoesNotExist(_transferId);
        _;
    }

    /// @notice Initialize the multisig contract
    /// @param _token The ERC721 token to be held and transferred by this vault
    /// @param _signers The array of multisig signers
    /// @param _quorum The number of signers required to execute a transfer
    constructor(address _token, address[] memory _signers, uint256 _quorum) {
        if (_signers.length == 0) revert SignersArrayCannotBeEmpty();
        if (_quorum > _signers.length) revert QuorumGreaterThanSigners();
        if (_quorum == 0) revert QuorumCannotBeZero();

        token = IERC721(_token);

        for (uint256 i = 0; i < _signers.length; i++) {
            address signer = _signers[i];
            // Reject the zero address and duplicate entries so that the
            // effective number of unique signers always matches _signers.length,
            // otherwise quorum could become unreachable (or a phantom signer registered).
            if (signer == address(0)) revert InvalidSignerAddress();
            if (multiSigSigners[signer]) revert DuplicateSigner(signer);

            multiSigSigners[signer] = true;
        }
        quorum = _quorum;
    }

    /// @notice Initiates a transfer; the initiator's approval is counted immediately
    /// @param _to The address of the recipient
    /// @param _tokenId The ID of the NFT to transfer
    function initiateTransfer(address _to, uint256 _tokenId) external onlyMultisigSigner {
        if (_to == address(0)) revert InvalidRecipient();
        // Must check ownership of the requested _tokenId directly: reading
        // transfer.tokenId here (before it is assigned below) would always
        // read the zero-initialized default of a fresh storage slot, i.e. it
        // would validate ownership of token ID 0 instead of the actual token
        // being transferred.
        if (token.ownerOf(_tokenId) != address(this)) revert TokenIsNotInWallet(_tokenId);

        uint256 transferId = transfersCount++;
        Transfer storage transfer = transfers[transferId];
        transfer.to = _to;
        transfer.tokenId = _tokenId;
        // The initiator implicitly approves their own transfer, so the approval
        // count must start at 1 to stay consistent with `approved[msg.sender] = true`
        // below (otherwise the initiator's vote would never be reflected in `approvals`,
        // and they would be permanently blocked from approving it later by
        // SignerAlreadyApproved).
        transfer.approvals = 1;
        transfer.executed = false;
        transfer.approved[msg.sender] = true;

        emit TransferInitiated(transferId, _to, _tokenId);
    }

    /// @notice Approves a pending transfer
    /// @param _transferId The ID of the transfer
    function approveTransfer(uint256 _transferId) external onlyMultisigSigner transferExists(_transferId) {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.executed) revert TransferAlreadyExecuted(_transferId);
        if (transfer.approved[msg.sender]) revert SignerAlreadyApproved(msg.sender);

        transfer.approvals++;
        transfer.approved[msg.sender] = true;

        emit TransferApproved(_transferId, msg.sender);
    }

    /// @notice Executes a transfer once quorum has been reached, sending the NFT to the recipient
    /// @param _transferId The ID of the transfer
    function executeTransfer(uint256 _transferId) external onlyMultisigSigner transferExists(_transferId) {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.approvals < quorum) revert QuorumHasNotBeenReached(_transferId);
        if (transfer.executed) revert TransferAlreadyExecuted(_transferId);

        if (token.ownerOf(transfer.tokenId) != address(this)) revert TokenIsNotInWallet(transfer.tokenId);

        // Effects before interaction: mark as executed before the external call.
        // safeTransferFrom invokes onERC721Received on contract recipients, which
        // is a reentrancy vector, so `executed` must already be true by then.
        transfer.executed = true;

        token.safeTransferFrom(address(this), transfer.to, transfer.tokenId);

        emit TransferExecuted(_transferId);
    }

    /// @notice Returns the stored details of a transfer
    /// @param _transferId The ID of the transfer
    /// @return to The recipient address
    /// @return tokenId The ID of the NFT being transferred
    /// @return approvals The number of approvals collected so far
    /// @return executed Whether the transfer has been executed
    function getTransfer(uint256 _transferId)
        external
        view
        returns (address to, uint256 tokenId, uint256 approvals, bool executed)
    {
        Transfer storage transfer = transfers[_transferId];
        return (transfer.to, transfer.tokenId, transfer.approvals, transfer.executed);
    }

    /// @notice Checks whether a given signer has approved a given transfer
    /// @param _transferId The ID of the transfer
    /// @param _signer The address of the signer to check
    /// @return Whether the signer has approved the transfer
    function hasSignedTransfer(uint256 _transferId, address _signer) external view returns (bool) {
        Transfer storage transfer = transfers[_transferId];
        return transfer.approved[_signer];
    }

    /// @notice Returns the total number of transfers ever initiated
    /// @return The total number of transfers
    function getTransfersCount() external view returns (uint256) {
        return transfersCount;
    }

    /// @notice Returns the address of the ERC721 token held by this vault
    /// @return The token contract address
    function getTokenAddress() external view returns (address) {
        return address(token);
    }
}
