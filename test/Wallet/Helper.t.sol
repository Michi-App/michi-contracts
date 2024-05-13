// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "erc6551/ERC6551Registry.sol";

import "tokenbound/src/AccountV3.sol";
import "tokenbound/src/AccountV3Upgradable.sol";
import "tokenbound/src/AccountProxy.sol";
import "tokenbound/src/AccountGuardian.sol";

import "tokenbound/lib/multicall-authenticated/src/Multicall3.sol";
import "../TestTokens/MockYT.sol";

import "src/MichiWalletNFT.sol";
import {MichiHelper} from "src/MichiHelper.sol";

contract HelperTestFuzz is Test {
    MichiWalletNFT public michiWalletNFT;
    MichiHelper public michiHelper;
    MockYT public mockYT;

    Multicall3 public multicall;
    AccountV3 public implementation;
    AccountV3Upgradable public upgradeableImplementation;
    AccountGuardian public guardian;
    AccountProxy public proxy;
    ERC6551Registry public registry;

    function setUp() public {
        address feeRecipient = vm.addr(5);

        michiWalletNFT = new MichiWalletNFT(0, 0.1 ether);
        registry = new ERC6551Registry();
        guardian = new AccountGuardian(address(this));
        multicall = new Multicall3();
        upgradeableImplementation =
            new AccountV3Upgradable(address(1), address(multicall), address(registry), address(guardian));
        proxy = new AccountProxy(address(guardian), address(upgradeableImplementation));
        mockYT = new MockYT();
        michiHelper = new MichiHelper(
            address(registry),
            address(upgradeableImplementation),
            address(proxy),
            address(michiWalletNFT),
            feeRecipient,
            0,
            10000
        );
    }

    function testCreateWallet(uint256 quantity) public {
        vm.assume(quantity > 0);
        vm.assume(quantity < 10);
        address user1 = vm.addr(1);
        vm.deal(user1, 10 ether);

        uint256 firstIdMinted = michiWalletNFT.currentIndex();

        uint256 mintCost = michiWalletNFT.getMintPrice() * quantity;
        vm.prank(user1);
        michiHelper.createWallet{value: mintCost}(quantity);

        uint256 nextId = michiWalletNFT.currentIndex();

        for (uint256 i = firstIdMinted; i < nextId; i++) {
            // check that nft is minted to user1
            assertEq(michiWalletNFT.ownerOf(i), user1);

            address computedAddress = registry.account(address(proxy), 0, block.chainid, address(michiWalletNFT), i);

            // check that predicted address is owned by user1
            AccountV3 account = AccountV3(payable(computedAddress));
            assertEq(account.owner(), user1);
        }
    }

    function testDepositAndWithdraw(uint256 amount) public {
        vm.assume(amount < 100000 ether);
        address user1 = vm.addr(1);
        address user2 = vm.addr(2);
        uint256 index = michiWalletNFT.currentIndex();
        vm.deal(user1, 10 ether);

        // compute predicted address using expected id
        address computedAddress = registry.account(address(proxy), 0, block.chainid, address(michiWalletNFT), index);

        vm.prank(user1);
        michiHelper.createWallet{value: 0.1 ether}(1);

        // mint mock YT tokens
        mockYT.mint(user1, amount);
        mockYT.mint(user2, amount);
        assertEq(mockYT.balanceOf(user1), amount);
        assertEq(mockYT.balanceOf(user2), amount);

        // add test YT to approved tokens list
        michiHelper.addApprovedToken(address(mockYT));
        assertEq(michiHelper.approvedToken(address(mockYT)), true);

        uint256 totalDepositAmount = amount;
        uint256 feeAmount = totalDepositAmount * michiHelper.depositFee() * michiHelper.feePrecision();
        uint256 depositAmountAfterFees = totalDepositAmount - feeAmount;

        // user2 should fail to deposit YT
        vm.prank(user2);
        mockYT.approve(address(michiHelper), amount);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(MichiHelper.UnauthorizedUser.selector, user2));
        michiHelper.depositToken(address(mockYT), computedAddress, amount, true);

        // user1 should succeed in depositing YT

        vm.prank(user1);
        mockYT.approve(address(michiHelper), amount);
        vm.prank(user1);
        michiHelper.depositToken(address(mockYT), computedAddress, amount, true);

        assertEq(mockYT.balanceOf(computedAddress), depositAmountAfterFees);
        assertEq(mockYT.balanceOf(michiHelper.feeReceiver()), feeAmount);
        assertEq(michiHelper.depositsByAccountByToken(computedAddress, address(mockYT)), depositAmountAfterFees);
        assertEq(michiHelper.depositsByToken(address(mockYT)), depositAmountAfterFees);
        assertEq(michiHelper.feesCollectedByToken(address(mockYT)), feeAmount);

        // user2 should fail transfering out YT
        AccountV3Upgradable account = AccountV3Upgradable(payable(computedAddress));
        bytes memory transferCall = abi.encodeWithSignature("transfer(address,uint256)", user1, depositAmountAfterFees);
        vm.prank(user2);
        vm.expectRevert(NotAuthorized.selector);
        account.execute(address(mockYT), 0, transferCall, 0);

        // user1 should success transfering out YT
        vm.prank(user1);
        account.execute(address(mockYT), 0, transferCall, 0);
        assertEq(mockYT.balanceOf(user1), depositAmountAfterFees);
    }
}
