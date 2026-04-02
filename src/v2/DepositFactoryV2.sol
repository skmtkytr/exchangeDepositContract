// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title DepositFactory v2
 * @author bitbank, inc.
 * @notice Deploys minimal proxy contracts for exchange deposit addresses via CREATE2.
 * @dev Uses the same 74-byte custom proxy bytecode as v1.
 * OZ Clones (EIP-1167) is NOT suitable here because it only supports DELEGATECALL,
 * but our proxies need CALL for ETH deposits (so msg.sender = proxy address)
 * and DELEGATECALL for function calls (gatherErc20, etc.).
 *
 * Improvements over v1:
 * - onlyOwner on deploy() to prevent front-running DoS
 * - predictAddress() for on-chain address prediction
 * - ProxyDeployed event for indexing
 * - Custom errors for gas efficiency
 */
contract DepositFactoryV2 is Ownable {
    // ─── Custom Errors ───
    error DeployFailed();

    // ─── Proxy init code ───
    // See ProxyFactory.sol (v1) for full bytecode explanation.
    //
    // Deploy code (10 bytes): stores runtime code in memory and returns it
    // Runtime code (64 bytes):
    //   - PUSH20 {ExchangeDeposit address}
    //   - if calldatasize == 0: CALL to ExchangeDeposit (ETH deposit)
    //   - if calldatasize > 0: DELEGATECALL to ExchangeDeposit (function call)
    //   - propagate return data or revert
    bytes private constant INIT_CODE =
        hex"604080600a3d393df3fe"
        hex"7300000000000000000000000000000000000000003d36602557"
        hex"3d3d3d3d34865af1603156"
        hex"5b363d3d373d3d363d855af4"
        hex"5b3d82803e603c573d81fd5b3d81f3";

    /// @notice The ExchangeDeposit contract address embedded in all proxies.
    address payable public immutable exchangeDeposit;

    // ─── Events ───

    /// @notice Emitted when a new deposit proxy is deployed.
    /// @param proxy The deployed proxy contract address.
    /// @param salt The salt used for CREATE2 deployment.
    event ProxyDeployed(address indexed proxy, bytes32 indexed salt);

    // ─── Constructor ───

    /// @param exchangeDepositAddr The main ExchangeDeposit contract address.
    /// @param initialOwner Admin who can deploy proxies (recommend multisig).
    constructor(
        address payable exchangeDepositAddr,
        address initialOwner
    ) Ownable(initialOwner) {
        exchangeDeposit = exchangeDepositAddr;
    }

    // ─── Deploy ───

    /// @notice Deploy a new deposit proxy via CREATE2.
    /// @dev Restricted to owner to prevent front-running DoS attacks.
    /// @param salt Unique salt for deterministic address derivation.
    /// @return dst The deployed proxy contract address.
    function deploy(bytes32 salt) external onlyOwner returns (address dst) {
        bytes memory initCode = INIT_CODE;
        address payable addr = exchangeDeposit;
        assembly {
            let pos := add(initCode, 0x20)
            let first32 := mload(pos)
            // Embed the ExchangeDeposit address into the PUSH20 slot
            mstore(pos, or(first32, shl(8, addr)))
            dst := create2(0, pos, 74, salt)
            if iszero(dst) {
                // Store DeployFailed() selector and revert
                mstore(0, 0x30116425)
                revert(0x1c, 0x04)
            }
        }
        emit ProxyDeployed(dst, salt);
    }

    /// @notice Deploy multiple proxies in a single transaction.
    /// @param salts Array of unique salts.
    /// @return proxies Array of deployed proxy addresses.
    function deployBatch(
        bytes32[] calldata salts
    ) external onlyOwner returns (address[] memory proxies) {
        proxies = new address[](salts.length);
        bytes memory initCode = INIT_CODE;
        address payable addr = exchangeDeposit;

        // Prepare the init code once (embed address)
        assembly {
            let pos := add(initCode, 0x20)
            mstore(pos, or(mload(pos), shl(8, addr)))
        }

        for (uint256 i = 0; i < salts.length; ) {
            address dst;
            bytes32 salt = salts[i];
            assembly {
                let pos := add(initCode, 0x20)
                dst := create2(0, pos, 74, salt)
                if iszero(dst) {
                    mstore(0, 0x30116425)
                    revert(0x1c, 0x04)
                }
            }
            proxies[i] = dst;
            emit ProxyDeployed(dst, salt);
            unchecked {
                ++i;
            }
        }
    }

    // ─── Address prediction ───

    /// @notice Predict the address of a proxy before deployment.
    /// @param salt The salt that will be used for CREATE2.
    /// @return predicted The predicted proxy contract address.
    function predictAddress(
        bytes32 salt
    ) external view returns (address predicted) {
        bytes32 initCodeHash = _getInitCodeHash();
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }

    /// @dev Compute the keccak256 hash of the init code with embedded address.
    function _getInitCodeHash() internal view returns (bytes32 hash) {
        bytes memory initCode = INIT_CODE;
        address payable addr = exchangeDeposit;
        assembly {
            let pos := add(initCode, 0x20)
            mstore(pos, or(mload(pos), shl(8, addr)))
            hash := keccak256(pos, 74)
        }
    }
}
