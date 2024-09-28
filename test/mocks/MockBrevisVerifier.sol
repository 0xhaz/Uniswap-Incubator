// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

contract MockBrevisVerifier {
    bool public verificationResult;
    bytes public lastProof;
    uint256[] public lastPublicInputs;

    function verifyProof(bytes calldata _proof, uint256[] calldata _publicInputs) external view returns (bool) {
        return verificationResult;
    }

    function setVerificationResult(bool _verificationResult) external {
        verificationResult = _verificationResult;
    }

    function getLastVerificationInputs() external view returns (bytes memory, uint256[] memory) {
        return (lastProof, lastPublicInputs);
    }

    function reset() external {
        verificationResult = false;
        delete lastProof;
        delete lastPublicInputs;
    }
}
