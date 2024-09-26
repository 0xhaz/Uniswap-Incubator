// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

interface IBrevisVerifier {
    function verifyProof(bytes calldata _proof, uint256[] calldata _publicInputs) external view returns (bool);
}
