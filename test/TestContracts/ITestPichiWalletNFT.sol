// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface ITestPichiWalletNFT {
    function getCurrentIndex() external view returns (uint256);

    function mint(address recipient) external;
}
