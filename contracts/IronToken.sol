// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IronToken
 * @notice Native ERC-20 token for the IronForge protocol.
 * @dev Implements the standard ERC-20 interface with owner-controlled minting
 *      and burning capabilities. Uses the direct approve/transferFrom pattern
 *      consistent with the original EIP-20 specification.
 *      Token symbol: IRON | Decimals: 18
 */
contract IronToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "IronToken: not owner");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == owner || msg.sender == from, "IronToken: not authorized");
        require(balanceOf[from] >= amount, "IronToken: insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "IronToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Set the allowance of `spender` over the caller's tokens.
     * @dev Overwrites any existing allowance. To safely change a non-zero
     *      allowance it is recommended to first reduce it to 0 and then set
     *      the desired value in a separate transaction.
     * @param spender The address authorised to spend on behalf of the caller.
     * @param amount  The maximum number of tokens the spender may transfer.
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "IronToken: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "IronToken: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
