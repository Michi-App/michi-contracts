// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "erc6551/interfaces/IERC6551Registry.sol";
import "tokenbound/src/AccountV3Upgradable.sol";
import "tokenbound/src/AccountProxy.sol";

import "./interfaces/IMichiWalletNFT.sol";

/**
 * @title MichiHelper
 *     @dev Implementation of a helper contract to create ERC-6551 accounts (TBAs)
 *     and deposit approved tokens to the TBA
 */
contract MichiHelper is Ownable {
    using SafeERC20 for IERC20;

    /// @notice instance of Michi Wallet NFT (NFT that represents 6551 wallet)
    IMichiWalletNFT public michiWalletNFT;

    /// @notice instance of ERC6551 Registry
    IERC6551Registry public erc6551Registry;

    /// @notice instance of current 6551 wallet implementation
    address public erc6551Implementation;

    /// @notice instance of current 6551 wallet proxy
    address public erc6551Proxy;

    /// @notice address that receives fees (if applicable)
    address public feeReceiver;

    /// @notice deposit fee
    uint256 public depositFee;

    /// @notice precision denominator
    uint256 public feePrecision;

    /// @notice tracks total deposits indexed by user and token
    mapping(address => mapping(address => uint256)) public depositsByAccountByToken;

    /// @notice tracks total deposits indexed by token
    mapping(address => uint256) public depositsByToken;

    /// @notice tracks total fees indexed by token
    mapping(address => uint256) public feesCollectedByToken;

    /// @notice tracks if token is approved to be deposited
    mapping(address => bool) public approvedToken;

    /// @notice array of approved tokens to be deposited
    address[] public listApprovedTokens;

    /// @notice emitted when a new wallet NFT is minted and corresponding 6551 wallet is initialized
    event WalletCreated(address indexed sender, address indexed walletAddress, address nftContract, uint256 tokenId);

    /// @notice emitted when an ERC-6551 wallet receives a deposit
    event Deposit(
        address indexed sender,
        address indexed walletAddress,
        address indexed token,
        uint256 amountAfterFees,
        uint256 feeTaken
    );

    /// @notice error returned when a user sends an invalid eth amount
    error InvalidPayableAmount(uint256 amount);

    /// @notice error returned when a user tries to deposit an unauthorized token
    error UnauthorizedToken(address token);

    /// @notice error returned when depositor is not the owner of 6551 wallet (safety precaution to prevent wrong deposits)
    error UnauthorizedUser(address user);

    /// @notice error returned when 6551 wallet owner is not sender
    error OwnerMismatch();

    /// @notice error returned when proposed deposit fee exceeds 5%
    error InvalidDepositFee(uint256 depositFee);

    /// @notice error returned when proposed fee recipient is zero address
    error InvalidFeeReceiver(address feeRecipient);

    /// @notice error returned when attempting to add an already approved token
    error TokenAlreadyApproved(address token);

    /// @notice error returned when attempting to remove an unapproved token
    error TokenNotApproved(address token);

    /// @dev constructor for MichiHelper contract
    /// @param erc6551Registry_ address of 6551 registry
    /// @param erc6551Implementation_ address of current 6551 implementation
    /// @param erc6551Proxy_ address of current 6551 proxy
    /// @param michiWalletNFT_ address of MichiWalletNFT ERC721
    /// @param feeReceiver_ address to receive deposit fees
    /// @param depositFee_ initial deposit fee
    /// @param feePrecision_ denominiator for fees
    constructor(
        address erc6551Registry_,
        address erc6551Implementation_,
        address erc6551Proxy_,
        address michiWalletNFT_,
        address feeReceiver_,
        uint256 depositFee_,
        uint256 feePrecision_
    ) {
        erc6551Registry = IERC6551Registry(erc6551Registry_);
        erc6551Implementation = erc6551Implementation_;
        erc6551Proxy = erc6551Proxy_;
        michiWalletNFT = IMichiWalletNFT(michiWalletNFT_);
        feeReceiver = feeReceiver_;
        depositFee = depositFee_;
        feePrecision = feePrecision_;
    }

    /// @dev mint MichiWalletNFT, deploy 6551 wallet owned by NFT, and initialize to current implementation
    /// @param quantity number of NFTs and wallets to setup
    function createWallet(uint256 quantity) external payable {
        uint256 mintPrice = michiWalletNFT.getMintPrice();
        if (msg.value != mintPrice * quantity) revert InvalidPayableAmount(msg.value);
        for (uint256 i = 0; i < quantity; i++) {
            uint256 currentIndex = michiWalletNFT.getCurrentIndex();
            michiWalletNFT.mint{value: mintPrice}(msg.sender);
            bytes32 salt = bytes32(abi.encode(0));
            address payable newWallet = payable(
                erc6551Registry.createAccount(erc6551Proxy, salt, block.chainid, address(michiWalletNFT), currentIndex)
            );
            AccountProxy(newWallet).initialize(erc6551Implementation);
            if (AccountV3Upgradable(newWallet).owner() != msg.sender) revert OwnerMismatch();
            emit WalletCreated(msg.sender, newWallet, address(michiWalletNFT), currentIndex);
        }
    }

    /// @dev deposit a supported token into ERC-6551 wallet
    /// @param token address of supported token to deposit
    /// @param walletAddress address of wallet to deposit into
    /// @param amount token amount of deposit
    /// @param takeFee boolean to pay a deposit fee
    function depositToken(address token, address walletAddress, uint256 amount, bool takeFee) external {
        if (AccountV3Upgradable(payable(walletAddress)).owner() != msg.sender) revert UnauthorizedUser(msg.sender);
        uint256 fee;
        if (!approvedToken[token]) revert UnauthorizedToken(token);
        if (takeFee && depositFee > 0) {
            fee = amount * depositFee / feePrecision;
            IERC20(token).safeTransferFrom(msg.sender, feeReceiver, fee);
            IERC20(token).safeTransferFrom(msg.sender, walletAddress, amount - fee);

            depositsByAccountByToken[walletAddress][token] += amount - fee;
            depositsByToken[token] += amount - fee;
            feesCollectedByToken[token] += fee;
        } else {
            IERC20(token).safeTransferFrom(msg.sender, walletAddress, amount);
            depositsByAccountByToken[walletAddress][token] += amount;
            depositsByToken[token] += amount;
        }

        emit Deposit(msg.sender, walletAddress, token, amount - fee, fee);
    }

    /// @dev add a supported token
    /// @param token address of new approved token
    function addApprovedToken(address token) external onlyOwner {
        if (approvedToken[token]) revert TokenAlreadyApproved(token);
        approvedToken[token] = true;
        listApprovedTokens.push(token);
    }

    /// @dev remove a supported token
    /// @param token address of token to be removed
    function removeApprovedToken(address token) external onlyOwner {
        if (!approvedToken[token]) revert TokenNotApproved(token);
        approvedToken[token] = false;
        uint256 arrayLength = listApprovedTokens.length;
        for (uint256 i = 0; i < arrayLength; i++) {
            if (listApprovedTokens[i] == token) {
                listApprovedTokens[i] = listApprovedTokens[arrayLength - 1];
                listApprovedTokens.pop();
                break;
            }
        }
    }

    /// @dev retrieve an array of approved tokens
    function getApprovedTokens() external view returns (address[] memory) {
        return listApprovedTokens;
    }

    /// @dev set a new deposit fee
    /// @param newDepositFee new deposit fee
    /// must be under 500 (500/10000 = 5%)
    function setDepositFee(uint256 newDepositFee) external onlyOwner {
        if (newDepositFee > 500) revert InvalidDepositFee(newDepositFee);
        depositFee = newDepositFee;
    }

    /// @dev set a new address to receive fees
    /// @param newFeeReceiver new address to receive fees
    function setFeeReceiver(address newFeeReceiver) external onlyOwner {
        if (newFeeReceiver == address(0)) revert InvalidFeeReceiver(newFeeReceiver);
        feeReceiver = newFeeReceiver;
    }

    /// @dev update to new erc-6551 implementation address
    /// @param newImplementation instance of new ERC-6551 implementation
    function updateImplementation(address newImplementation) external onlyOwner {
        erc6551Implementation = newImplementation;
    }

    /// @dev update to new erc-6551 proxy address
    /// @param newProxy instance of new ERC-6551 proxy
    function updateProxy(address newProxy) external onlyOwner {
        erc6551Proxy = newProxy;
    }
}
