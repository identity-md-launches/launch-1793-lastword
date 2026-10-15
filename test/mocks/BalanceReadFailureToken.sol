// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test-only ERC-20 fixture that can fail a balance query before or after transferFrom.
contract BalanceReadFailureToken {
    enum Fault {
        None,
        RevertBeforeTransfer,
        RevertAfterTransfer,
        EmptyAfterTransfer,
        ShortAfterTransfer
    }

    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) public allowance;
    Fault public fault;
    bool public transferred;

    error BalanceReadRejected();

    function mint(address author, uint256 amount) external {
        totalSupply += amount;
        _balances[author] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setFault(Fault value) external {
        fault = value;
        transferred = false;
    }

    function rawBalanceOf(address author) external view returns (uint256) {
        return _balances[author];
    }

    function balanceOf(address author) external view returns (uint256) {
        if (fault == Fault.RevertBeforeTransfer || (transferred && fault == Fault.RevertAfterTransfer)) {
            revert BalanceReadRejected();
        }
        if (transferred && fault == Fault.EmptyAfterTransfer) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (transferred && fault == Fault.ShortAfterTransfer) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 31)
            }
        }
        return _balances[author];
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "fixture: allowance");
        require(_balances[from] >= amount, "fixture: balance");
        allowance[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        transferred = true;
        return true;
    }
}
