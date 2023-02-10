// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "./Pool.sol";

/// @title Factory
/// @author Moaz Mohsen & Nour Haridy
/// @notice This contract is responsible for deploying new pools and providing them with the current fee and fee recipient
contract Factory {

    address public operator;
    address public pendingOperator;
    address public feeRecipient;
    uint public feeMantissa;
    uint public constant MAX_FEE_MANTISSA = 0.2e18;
    bytes16 private constant _SYMBOLS = "0123456789abcdef";
    bytes32 public immutable POOL_SYMBOL_PREFIX;
    mapping (Pool => bool) public isPool;
    Pool[] public pools;

    constructor(address _operator, string memory _poolSymbolPrefix) {
        operator = _operator;
        POOL_SYMBOL_PREFIX = pack(_poolSymbolPrefix);
    }

    function pack(string memory unpacked) internal pure returns (bytes32 packed) {
        require (bytes(unpacked).length < 32);
        assembly {
            packed := mload (add (unpacked, 31))
        }
    }

    function unpack(bytes32 packed) internal pure returns (string memory unpacked) {
        uint l = uint (packed >> 248);
        require (l < 32);
        unpacked = string (new bytes (l));
        assembly {
            mstore (add (unpacked, 31), packed) // Potentially writes into unallocated memory, which is fine
        }
    }

    /// @notice Get the number of deployed pools
    /// @return uint number of deployed pools
    /// @dev Useful for iterating on all pools
    function getPoolsLength() external view returns (uint) {
        return pools.length;
    }

    /// @notice Set the fee recipient for all pools
    /// @param _feeRecipient address of the new fee recipient
    /// @dev Only callable by the operator
    function setFeeRecipient(address _feeRecipient) external {
        require(msg.sender == operator, "Factory: not operator");
        feeRecipient = _feeRecipient;
    }

    /// @notice Set the fee for all pools
    /// @param _feeMantissa the new fee amount in Mantissa (scaled by 1e18)
    /// @dev Only callable by the operator
    function setFeeMantissa(uint _feeMantissa) external {
        require(msg.sender == operator, "Factory: not operator");
        require(_feeMantissa <= MAX_FEE_MANTISSA, "Factory: fee too high");
        if(_feeMantissa > 0) require(feeRecipient != address(0), "Factory: fee recipient is zero address");
        feeMantissa = _feeMantissa;
    }

    /// @notice Set a pending operator for the factory
    /// @param _pendingOperator address of the new pending operator
    /// @dev Only callable by the operator
    function setPendingOperator(address _pendingOperator) external {
        require(msg.sender == operator, "Factory: not operator");
        pendingOperator = _pendingOperator;
    }

    /// @notice Accept the pending operator
    /// @dev Only callable by the pending operator
    function acceptOperator() external {
        require(msg.sender == pendingOperator, "Factory: not pending operator");
        operator = pendingOperator;
        pendingOperator = address(0);
    }

    /// @notice Get the fee and fee recipient for all pools
    /// @return address of the fee recipient and the fee amount in Mantissa (scaled by 1e18)
    /// @dev Used by pools to access the current fee and fee recipient
    function getFee() external view returns (address, uint) {
        uint _feeMantissa = feeMantissa;
        if(_feeMantissa == 0) return (address(0), 0);
        return (feeRecipient, _feeMantissa);
    }

    /// @dev Return the log in base 10, rounded down, of a positive value. Returns 0 if given 0.
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }    


    /// @dev Converts a `uint256` to its ASCII `string` decimal representation.
    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            uint256 length = log10(value) + 1;
            string memory buffer = new string(length);
            uint256 ptr;
            /// @solidity memory-safe-assembly
            assembly {
                ptr := add(buffer, add(32, length))
            }
            while (true) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, byte(mod(value, 10), _SYMBOLS))
                }
                value /= 10;
                if (value == 0) break;
            }
            return buffer;
        }
    }

    /// @notice Deploy a new Surge pool
    /// @param _collateralToken address of the collateral token
    /// @param _loanToken address of the loan token
    /// @param _maxCollateralRatioMantissa the maximum collateral ratio in Mantissa (scaled by 1e18)
    /// @param _surgeMantissa the surge utilization threshold in Mantissa (scaled by 1e18)
    /// @param _collateralRatioFallDuration the duration of the collateral ratio fall in seconds
    /// @param _collateralRatioRecoveryDuration the duration of the collateral ratio recovery in seconds
    /// @param _minRateMantissa the minimum interest rate in Mantissa (scaled by 1e18)
    /// @param _surgeRateMantissa the interest rate at the surge threshold in Mantissa (scaled by 1e18)
    /// @param _maxRateMantissa the maximum interest rate in Mantissa (scaled by 1e18)
    /// @return Pool the address of the deployed pool
    function deploySurgePool(
        IERC20 _collateralToken,
        IERC20 _loanToken,
        uint _maxCollateralRatioMantissa,
        uint _surgeMantissa,
        uint _collateralRatioFallDuration,
        uint _collateralRatioRecoveryDuration,
        uint _minRateMantissa,
        uint _surgeRateMantissa,
        uint _maxRateMantissa
    ) external returns (Pool) {
        string memory poolNumberString = toString(pools.length);
        string memory prefix = unpack(POOL_SYMBOL_PREFIX);
        Pool pool = new Pool(
            string(abi.encodePacked(prefix, poolNumberString)),
            string(abi.encodePacked("Surge ", prefix, poolNumberString, " Pool")),
            _collateralToken,
            _loanToken,
            _maxCollateralRatioMantissa,
            _surgeMantissa,
            _collateralRatioFallDuration,
            _collateralRatioRecoveryDuration,
            _minRateMantissa,
            _surgeRateMantissa,
            _maxRateMantissa
        );
        isPool[pool] = true;
        emit PoolDeployed(pools.length, address(pool), address(_collateralToken), address(_loanToken), _maxCollateralRatioMantissa, _surgeMantissa, _collateralRatioFallDuration, _collateralRatioRecoveryDuration, _minRateMantissa, _surgeRateMantissa, _maxRateMantissa);
        pools.push(pool);
        return pool;
    }
    event PoolDeployed(uint poolId, address pool, address indexed collateralToken, address indexed loanToken, uint indexed maxCollateralRatioMantissa, uint surgeMantissa, uint collateralRatioFallDuration, uint collateralRatioRecoveryDuration, uint minRateMantissa, uint surgeRateMantissa, uint maxRateMantissa);
}