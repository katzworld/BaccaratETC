// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract BaccaratETC is Ownable {
    using SafeERC20 for IERC20;

    uint256 public maxBet;
    uint256 public houseCutPercentage; // 1 = 1%, 100 = 100%
    uint256 public constant HOUSE_MIN_CUT = 1;
    
    enum Position { Banker, Player }
    enum GameResult { Banker, Player, Tie }
    
    struct Game {
        address player;
        address token;
        uint256 amount;
        Position position;
        uint256 commitBlock;
        bool resolved;
    }

    mapping(address => mapping(address => uint256)) public balances; // user => token => balance
    mapping(address => Game) public games;
    mapping(address => bool) public allowedTokens;
    mapping(address => uint256) public houseBalances; // token => balance
    bool public paused;

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event GameStarted(address indexed player, address indexed token, uint256 amount, Position position);
    event GameResolved(address indexed player, address indexed token, GameResult result, uint256 payout);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event Paused(address account);
    event Unpaused(address account);
    event MaxBetUpdated(uint256 newMaxBet);
    event HouseCutUpdated(uint256 newHouseCutPercentage);
    event ContractFunded(address indexed token, uint256 amount);

    constructor() Ownable(msg.sender) {
        maxBet = 10; // Default max bet
        houseCutPercentage = 5; // Default 5% house cut
    }

    modifier validToken(address token) {
        require(allowedTokens[token], "Token not allowed");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "Contract not paused");
        _;
    }

    function setMaxBet(uint256 newMaxBet) external onlyOwner {
        require(newMaxBet > 0, "Max bet must be positive");
        maxBet = newMaxBet;
        emit MaxBetUpdated(newMaxBet);
    }

    function setHouseCutPercentage(uint256 newPercentage) external onlyOwner {
        require(newPercentage > 0 && newPercentage <= 100, "Invalid percentage");
        houseCutPercentage = newPercentage;
        emit HouseCutUpdated(newPercentage);
    }

    function fundContract(address tokenAddress, uint256 amount) external onlyOwner validToken(tokenAddress) {
        require(amount > 0, "Amount must be positive");
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        houseBalances[tokenAddress] += amount;
        emit ContractFunded(tokenAddress, amount);
    }

    function addToken(address tokenAddress) external onlyOwner {
        IERC20Decimals token = IERC20Decimals(tokenAddress);
        require(token.decimals() == 0, "Token must have 0 decimals");
        allowedTokens[tokenAddress] = true;
        emit TokenAdded(tokenAddress);
    }

    function removeToken(address tokenAddress) external onlyOwner {
        allowedTokens[tokenAddress] = false;
        emit TokenRemoved(tokenAddress);
    }

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function deposit(uint256 amount, address tokenAddress) external validToken(tokenAddress) whenNotPaused {
        require(amount > 0, "Deposit amount must be positive");
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender][tokenAddress] += amount;
        emit Deposited(msg.sender, tokenAddress, amount);
    }

    function startGame(uint256 amount, Position position, address tokenAddress) external validToken(tokenAddress) whenNotPaused {
        require(amount > 0 && amount <= maxBet, "Invalid bet amount");
        require(balances[msg.sender][tokenAddress] >= amount, "Insufficient balance");
        require(games[msg.sender].commitBlock == 0, "Existing game pending");

        balances[msg.sender][tokenAddress] -= amount;
        
        games[msg.sender] = Game({
            player: msg.sender,
            token: tokenAddress,
            amount: amount,
            position: position,
            commitBlock: block.number,
            resolved: false
        });

        emit GameStarted(msg.sender, tokenAddress, amount, position);
    }

    function resolveGame() external whenNotPaused {
        Game storage game = games[msg.sender];
        require(game.commitBlock != 0, "No active game");
        require(block.number > game.commitBlock, "Wait for next block");
        require(!game.resolved, "Game already resolved");

        game.resolved = true;
        (uint8 banker, uint8 player) = _generateResults(game.commitBlock);
        GameResult result = _determineResult(banker, player);

        uint256 payout = _calculatePayout(game.amount, game.position, result);
        
        if (payout > 0) {
            balances[game.player][game.token] += payout;
        }

        emit GameResolved(game.player, game.token, result, payout);
        delete games[msg.sender];
    }

    function closeout(address tokenAddress) external onlyOwner whenPaused validToken(tokenAddress) {
        // Get total contract balance
        uint256 contractBalance = IERC20(tokenAddress).balanceOf(address(this));
        
        // Reset house balance
        houseBalances[tokenAddress] = 0;
        
        // Transfer all remaining balance to owner
        if (contractBalance > 0) {
            IERC20(tokenAddress).safeTransfer(owner(), contractBalance);
        }
    }

    function _generateResults(uint256 commitBlock) internal view returns (uint8, uint8) {
        bytes32 futureHash = blockhash(commitBlock + 1);
        require(futureHash != 0, "Blockhash unavailable");

        uint256 rand = uint256(futureHash);
        return (
            uint8(uint256(keccak256(abi.encodePacked(rand, "banker"))) % 10),
            uint8(uint256(keccak256(abi.encodePacked(rand, "player"))) % 10)
        );
    }

    function _determineResult(uint8 banker, uint8 player) internal pure returns (GameResult) {
        if (banker > player) return GameResult.Banker;
        if (player > banker) return GameResult.Player;
        return GameResult.Tie;
    }

    function _calculatePayout(uint256 betAmount, Position position, GameResult result) internal returns (uint256) {
        Game storage game = games[msg.sender];
        
        if (result == GameResult.Tie) {
            // On tie, return original bet and ensure house balance isn't affected
            houseBalances[game.token] -= betAmount; // Remove the bet from house balance
            return betAmount; // PUSH - return original bet on tie
        }

        if (uint(position) != uint(result)) {
            // Player lost - bet goes to house
            houseBalances[game.token] += betAmount;
            return 0;
        }

        if (position == Position.Banker) {
            // For Banker wins, implement (19/20) payout structure
            uint256 totalPayout = betAmount * 2; // Total amount including original bet
            uint256 commission = (totalPayout * houseCutPercentage) / 100;
            
            if (commission < HOUSE_MIN_CUT) {
                commission = HOUSE_MIN_CUT;
            }
            
            uint256 payout = totalPayout - commission;
            houseBalances[game.token] += commission;
            houseBalances[game.token] -= betAmount; // Remove the original bet from house balance
            return payout;
        }

        // Player win on Player position
        uint256 playerPayout = betAmount * 2;
        require(houseBalances[game.token] >= playerPayout, "Insufficient house balance");
        houseBalances[game.token] -= playerPayout;
        return playerPayout;
    }

    function withdraw(uint256 amount, address tokenAddress) external validToken(tokenAddress) whenNotPaused {
        require(balances[msg.sender][tokenAddress] >= amount, "Insufficient balance");
        balances[msg.sender][tokenAddress] -= amount;
        IERC20(tokenAddress).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, tokenAddress, amount);
    }
}
