// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract VaultMultisigERC20 {

    IERC721 public token;

        /// @notice The number of signatures required to execute a transaction
    uint256 public quorum;

    /// @notice The number of transfers executed
    uint256 public transfersCount;

    /// @dev The struct is used to store the details of a transfer
    /// @param to The address of the recipient
    /// @param amount The amount of tokens to transfer
    /// @param approvals The number of approvals required to execute the transfer
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
    mapping (uint256 => Transfer) private transfers;

    /// @notice The mapping for verification that address is a signer
    mapping (address => bool) private multiSigSigners;

    /// @notice Checks that signers array is not empty
    error SignersArrayCannotBeEmpty();

    /// @notice Checks that quorum is not greater than the number of signers
    error QuorumGreaterThanSigners();

    /// @notice Checks that quorum is greater than zero
    error QuorumCannotBeZero();

    /// @notice Checks that the recipient is not zero address
    error InvalidRecipient();

    /// @notice Checks that amount is greater than zero
    error InvalidAmount();

    /// @notice Checks that the signer is a multisig signer
    error InvalidMultisigSigner();

    /// @notice Checks that the transfer is not already executed
    /// @param transferId The ID of the transfer
    error TransferAlreadyExecuted(uint256 transferId);

    /// @notice Checks that the signer has already approved the transfer
    /// @param signer The address of the signer
    error SignerAlreadyApproved(address signer);

    /// @notice Checks that quorum was reached for transfer
    /// @param transferId The ID of the transfer
    error QuorumHasNotBeenReached(uint256 transferId);

    /// @notice Checks that the contract balance is sufficient to cover the transfer amount
    /// @param available The current balance of the contract
    /// @param required The amount requested by the transfer
    error InsufficientBalance(uint256 available, uint256 required);

    /// @notice Thrown when the low-level ETH call to the recipient fails
    /// @param transferId The ID of the transfer
    error TransferFailed(uint256 transferId);

    error TokenIsNotInWallet(uint256 tokenId);

    /// @notice Emitted when a new transfer is initiated
    event TransferInitiated(uint256 indexed transferId, address indexed to, uint256 tokenId);

    /// @notice Emitted when a signer approves a pending transfer
    event TransferApproved(uint256 transferId, address signer);

    /// @notice Emitted when a transfer is executed and funds are sent
    event TransferExecuted(uint256 transferId);

    /// @notice Restricts a function to addresses registered as multisig signers
    modifier onlyMultisigSigner() {
        if (!multiSigSigners[msg.sender]) revert InvalidMultisigSigner();
        _;
    }

    constructor(address _token, address[] memory _signers, uint256 _quorum) {
        if (_signers.length == 0) revert SignersArrayCannotBeEmpty();
        if (_quorum > _signers.length) revert QuorumGreaterThanSigners();
        if (_quorum == 0) revert QuorumCannotBeZero();

        token = IERC721(_token);

        for (uint256 i = 0; i < _signers.length; i++) {
            multiSigSigners[_signers[i]] = true;
        }
        quorum = _quorum;
    }

    /// @notice Initiates a transfer
    /// @param _to The address of the recipient
    function initiateTransfer(address _to, uint256 _tokenId) external onlyMultisigSigner {
        if (_to == address(0)) revert InvalidRecipient();

        uint256 transferId = transfersCount++;
        Transfer storage transfer = transfers[transferId];
        if (token.ownerOf(transfer.tokenId) != address(this)) revert TokenIsNotInWallet(transfer.tokenId);

        transfer.to = _to;
        transfer.tokenId = _tokenId;
        transfer.approvals = 0;
        transfer.executed = false;
        transfer.approved[msg.sender] = true;

        emit TransferInitiated(transferId, _to, _tokenId);
    }

    /// @notice Approves a transfer
    /// @param _transferId The ID of the transfer
    function approveTransfer(uint256 _transferId) external onlyMultisigSigner {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.executed) revert TransferAlreadyExecuted(_transferId);
        if (transfer.approved[msg.sender]) revert SignerAlreadyApproved(msg.sender);

        transfer.approvals++;
        transfer.approved[msg.sender] = true;

        emit TransferApproved(_transferId, msg.sender);
    }

    function executeTransfer(uint256 _transferId) external onlyMultisigSigner {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.approvals < quorum) revert QuorumHasNotBeenReached(_transferId);
        if (transfer.executed) revert TransferAlreadyExecuted(_transferId);

        if (token.ownerOf(transfer.tokenId) != address(this)) revert TokenIsNotInWallet(transfer.tokenId);

        token.safeTransferFrom(address(this), transfer.to, transfer.tokenId);

        transfer.executed = true;

        emit TransferExecuted(_transferId);
    }

    /// @notice Default fallback function for receiving ETH
    receive() external payable {}

    function getTransfer(uint256 _transferId) external view returns (
        address to,
        uint256 tokenId,
        uint256 approvals,
        bool executed
    ) {
        Transfer storage transfer = transfers[_transferId];
        return (transfer.to, transfer.tokenId, transfer.approvals, transfer.executed);
    }

    function hasSignedTransfer(uint256 _transferId, address _signer) external view returns (bool) {
        Transfer storage transfer = transfers[_transferId];
        return transfer.approved[_signer];
    }

    function getTransfersCount() external view returns (uint256) {
        return transfersCount;
    }

    function getTokenAddress() external view returns (address) {
        return address(token);
    }
}
