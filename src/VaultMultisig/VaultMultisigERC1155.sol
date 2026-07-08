// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract VaultMultisigERC1155 {
    /// @notice The ERC1155 token held and transferred by this vault
    IERC1155 public token;

    /// @notice The number of signatures required to execute a transfer
    uint256 public quorum;

    /// @notice The total number of transfers ever initiated (also used as the next transfer ID)
    uint256 public transfersCount;

    /// @dev The struct is used to store the details of a transfer
    /// @param to The address of the recipient
    /// @param tokenId The ID of the ERC1155 token type to transfer
    /// @param amount The amount of tokens to transfer
    /// @param approvals The number of approvals collected so far
    /// @param executed Whether the transfer has been executed
    /// @param approved The mapping of signers to their approval status
    struct Transfer {
        address to;
        uint256 tokenId;
        uint256 amount;
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

    /// @notice Thrown when the requested transfer amount is zero
    error InvalidAmount();

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

    /// @notice Thrown when the vault does not currently hold enough of the requested token type
    /// @param tokenId The ID of the ERC1155 token type that is insufficiently funded
    error NotEnoughTokens(uint256 tokenId);

    /// @notice Emitted when a new transfer is initiated
    event TransferInitiated(uint256 indexed transferId, address indexed to, uint256 tokenId, uint256 amount);

    /// @notice Emitted when a signer approves a pending transfer
    event TransferApproved(uint256 transferId, address signer);

    /// @notice Emitted when a transfer is executed and tokens are sent
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
    /// @param _token The ERC1155 token to be held and transferred by this vault
    /// @param _signers The array of multisig signers
    /// @param _quorum The number of signers required to execute a transfer
    constructor(address _token, address[] memory _signers, uint256 _quorum) {
        if (_signers.length == 0) revert SignersArrayCannotBeEmpty();
        if (_quorum > _signers.length) revert QuorumGreaterThanSigners();
        if (_quorum == 0) revert QuorumCannotBeZero();

        token = IERC1155(_token);

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
    /// @param _tokenId The ID of the ERC1155 token type to transfer
    /// @param _amount The amount of tokens to transfer
    function initiateTransfer(address _to, uint256 _tokenId, uint256 _amount) external onlyMultisigSigner {
        if (_to == address(0)) revert InvalidRecipient();
        if (_amount == 0) revert InvalidAmount();
        // Must check the balance for the requested _tokenId/_amount directly:
        // reading transfer.tokenId/transfer.amount here (before they are assigned
        // below) would read the zero-initialized defaults of a fresh storage slot,
        // making the check `balanceOf(...) < 0`, which for a uint256 is always
        // false — i.e. the validation would never actually run.
        if (token.balanceOf(address(this), _tokenId) < _amount) revert NotEnoughTokens(_tokenId);

        uint256 transferId = transfersCount++;
        Transfer storage transfer = transfers[transferId];
        transfer.to = _to;
        transfer.tokenId = _tokenId;
        transfer.amount = _amount;
        // The initiator implicitly approves their own transfer, so the approval
        // count must start at 1 to stay consistent with `approved[msg.sender] = true`
        // below (otherwise the initiator's vote would never be reflected in `approvals`,
        // and they would be permanently blocked from approving it later by
        // SignerAlreadyApproved).
        transfer.approvals = 1;
        transfer.executed = false;
        transfer.approved[msg.sender] = true;

        emit TransferInitiated(transferId, _to, _tokenId, _amount);
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

    /// @notice Executes a transfer once quorum has been reached, sending tokens to the recipient
    /// @param _transferId The ID of the transfer
    function executeTransfer(uint256 _transferId) external onlyMultisigSigner transferExists(_transferId) {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.approvals < quorum) revert QuorumHasNotBeenReached(_transferId);
        if (transfer.executed) revert TransferAlreadyExecuted(_transferId);

        if (token.balanceOf(address(this), transfer.tokenId) < transfer.amount) {
            revert NotEnoughTokens(transfer.tokenId);
        }

        // Effects before interaction: mark as executed before the external call.
        // safeTransferFrom invokes onERC1155Received on contract recipients, which
        // is a reentrancy vector, so `executed` must already be true by then.
        transfer.executed = true;

        token.safeTransferFrom(address(this), transfer.to, transfer.tokenId, transfer.amount, "");

        emit TransferExecuted(_transferId);
    }

    /// @notice Returns the stored details of a transfer
    /// @param _transferId The ID of the transfer
    /// @return to The recipient address
    /// @return tokenId The ID of the ERC1155 token type being transferred
    /// @return amount The amount of the transfer
    /// @return approvals The number of approvals collected so far
    /// @return executed Whether the transfer has been executed
    function getTransfer(uint256 _transferId)
        external
        view
        returns (address to, uint256 tokenId, uint256 amount, uint256 approvals, bool executed)
    {
        Transfer storage transfer = transfers[_transferId];
        return (transfer.to, transfer.tokenId, transfer.amount, transfer.approvals, transfer.executed);
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

    /// @notice Returns the address of the ERC1155 token held by this vault
    /// @return The token contract address
    function getTokenAddress() external view returns (address) {
        return address(token);
    }
}
