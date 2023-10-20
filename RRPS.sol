// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/*
0. mint()       - Pay ETH to mint cards. Can mint multiple times
1. commit()     - Both players commit in the same transaction. This can be combined off-chain
2. reveal()     - Players reveal asynchronously. Both players must submit within a timeframe
3. close()      - Anyone can call this function to determine the winner
4. reset()      - Closes game and allows players to commit() again
4. withdraw()   - Trade Stars for ETH. Player must have stars && no cards
*/

contract RRPS is ERC1155 {
    using ECDSA for bytes32;

    constructor() ERC1155("https://rrps.app") {}

    // card ids
    uint ROCK = 1;
    uint PAPER = 2;
    uint SCISSOR = 3;

    // list of players
    mapping (address => Player) players;

    // list of games
    mapping(uint => Game) public games;

    // player info
    struct Player {
        uint stars;
        bool inGame;
    }

    // game info
    struct Game {
        address player1;
        address player2;
        bytes32 commit1;
        bytes32 commit2;
        uint reveal1;
        uint reveal2;
        uint blockNum;
        bool complete;
    }

    /*
     * Pay ETH to mint cards. Can mint multiple times
     * Getting more cards in RRPS isn’t always desirable
     */
    function mint() public payable {
        require(msg.value == 1 ether, "Must Pay to Start");
        players[msg.sender].stars = players[msg.sender].stars + 3;
        _mint(msg.sender, ROCK, 4, "");
        _mint(msg.sender, PAPER, 4, "");
        _mint(msg.sender, SCISSOR, 4, "");
    }

    /*
     * Both players commit at the same time
     * @param _game id aka empty lobby number
     *
     * @param _signature1 player 1's commit signature
     * @param _to1 address of opponent aka player2 address
     * @param _commitHash1 player 1's commit hash
     *
     * @param _signature2 player 2's commit signature
     * @param _to2 address of opponent aka player1 address
     * @param _commitHash2 player 2's commit hash
     */
    function commit(
        uint _game,
        bytes memory _signature1,
        address _to1,
        bytes32 _commitHash1,
        bytes memory _signature2,
        address _to2,
        bytes32 _commitHash2
    ) public {
        require(players[_to1].inGame == false, "Player 1 In Game");
        require(players[_to2].inGame == false, "Player 2 In Game");
        require(games[_game].blockNum > 0, "Game Exists");
        // verify player signature
        address player1 = getSigner(_signature1, _game, _to1, _commitHash1);
        address player2 = getSigner(_signature2, _game, _to2, _commitHash2);
        // player has stars
        require(players[player1].stars > 0, "Player1 Has No Stars");
        require(players[player2].stars > 0, "Player2 Has No Stars");
        // both opponents agree to each other
        require(_to1 == player2, "Incorrect Opponent");
        require(_to2 == player1, "Incorrect Opponent");
        // set timeline to reveal cards
        games[_game].blockNum = block.number + 10;
        players[_to1].inGame = true;
        players[_to2].inGame = true;
        games[_game].player1 = player1;
        games[_game].player2 = player2;
        games[_game].commit1 = _commitHash1;
        games[_game].commit2 = _commitHash2;
    }

    /*
     * Reveal cards
     * @param _game id aka lobby number
     * @param _nonce is a random secret number
     * @param _card (ROCK = 1, PAPER = 2, SCISSOR = 3)
     */
    function reveal(uint _game, uint _nonce, uint _card) public {
        require(
            _card == ROCK || _card == PAPER || _card == SCISSOR,
            "Invalid Card"
        );
        bytes32 hashedCommit = hashCommit(_nonce, _card);
        // hashed commit must match games commit
        if (hashedCommit == games[_game].commit1) {
            games[_game].reveal1 = _card;
        }
        if (hashedCommit == games[_game].commit2) {
            games[_game].reveal2 = _card;
        }
        // if both cards are revealed, then handle
        if (games[_game].reveal1 != 0 && games[_game].reveal2 != 0) {
            close(_game);
        }
    }

    /*
     * Handle Winner/Loser logic 
     * @param _game id aka lobby number
     */
    function close(uint _game) public returns (bool) {
        require(games[_game].complete == false, "Game Already Over");
        require(
            balanceOf(games[_game].player1, games[_game].reveal1) > 0,
            "Player1 Has No Card"
        );
        require(
            balanceOf(games[_game].player2, games[_game].reveal2) > 0,
            "Player2 Has No Card"
        );
        require(players[games[_game].player1].stars > 0, "Player1 Has No Stars");
        require(players[games[_game].player2].stars > 0, "Player2 Has No Stars");
        // if game expired and neither revealed
        if (
            block.number > games[_game].blockNum &&
            games[_game].reveal1 == 0 &&
            games[_game].reveal2 == 0
        ) {
            reset(_game);
        }
        // if game expired, player1 revealed & player2 hasn't revealed
        if (
            block.number > games[_game].blockNum &&
            games[_game].reveal1 > 0 &&
            games[_game].reveal2 == 0
        ) {
            // player2 loses 1 star
            reset(_game);
            players[games[_game].player1].stars ++;
            players[games[_game].player2].stars --;
            return true;
        }
        // if game expired, player2 revealed & player1 hasn't revealed
        if (
            block.number > games[_game].blockNum &&
            games[_game].reveal2 > 0 &&
            games[_game].reveal1 == 0
        ) {
            // player1 loses 1 star
            reset(_game);
            players[games[_game].player1].stars --;
            players[games[_game].player2].stars ++;
            return true;
        }
        // tie
        if (games[_game].reveal1 == games[_game].reveal2) {
            reset(_game);
        }
        // player1 wins
        if (
            (games[_game].reveal1 == ROCK && games[_game].reveal2 == SCISSOR) ||
            (games[_game].reveal1 == PAPER && games[_game].reveal2 == ROCK) ||
            (games[_game].reveal1 == SCISSOR && games[_game].reveal2 == PAPER)
        ) {
            // transfer & burn
            reset(_game);
            players[games[_game].player1].stars ++;
            players[games[_game].player2].stars --;
            _burn(games[_game].player1, games[_game].reveal1, 1);
            _burn(games[_game].player2, games[_game].reveal2, 1);
            return true;
        }
        // player2 wins
        if (
            (games[_game].reveal2 == ROCK && games[_game].reveal1 == SCISSOR) ||
            (games[_game].reveal2 == PAPER && games[_game].reveal1 == ROCK) ||
            (games[_game].reveal2 == SCISSOR && games[_game].reveal1 == PAPER)
        ) {
            // transfer & burn
            reset(_game);
            players[games[_game].player1].stars --;
            players[games[_game].player2].stars ++;
            _burn(games[_game].player1, games[_game].reveal1, 1);
            _burn(games[_game].player2, games[_game].reveal2, 1);
            return true;
        }
        return false; // this means I'm missing logic somewhere
    }

    /*
     * Reset game: mark as complete and take players out of game
     * @param _game id aka lobby number
     */
    function reset(uint _game) private {
        games[_game].complete = true;
        players[games[_game].player1].inGame = false;
        players[games[_game].player2].inGame = false;
    }

    /*
     * Trade Stars for ETH
     * Player must have stars && no cards
     * @return data
     */
    function withdraw() public payable returns (bytes memory) {
        require(players[msg.sender].stars > 0, "Has No Stars");
        require(balanceOf(msg.sender, ROCK) == 0, "Has Rock Card");
        require(balanceOf(msg.sender, PAPER) == 0, "Has Paper Card");
        require(balanceOf(msg.sender, SCISSOR) == 0, "Has Scissor Card");

        // 0.3 ETH per Star on a 1 ETH buy in
        uint value = (players[msg.sender].stars * 3) / 100;

        // burn stars
        players[msg.sender].stars = 0;

        // transfer ETH
        (bool sent, bytes memory data) = msg.sender.call{value: value}("");
        require(sent, "Failed to send Ether");

        return data;
    }

    /*
     * Helper function to create commit hash
     * @param _nonce is a random secret number
     * @param _card (ROCK = 1, PAPER = 2, SCISSOR = 3)
     * @return the hash of _nonce + _card
     */
    function hashCommit(uint _nonce, uint _card) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_nonce, _card));
    }

    /*
     * Helper function to get address of signer
     * @param _signature EIP712
     * @param _game id aka lobby number
     * @param _to address of opponent
     * @param _commitHash = nonce + card
     */
    function getSigner(
        bytes memory _signature,
        uint256 _game,
        address _to,
        bytes32 _commitHash
    ) public pure returns (address) {
        // EIP721 domain type
        string memory name = "RRPS";
        string memory version = "1";
        uint256 chainId = 1;
        address verifyingContract = 0x0000000000000000000000000000000000000000; // address(this);

        // stringified types
        string
            memory EIP712_DOMAIN_TYPE = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
        string
            memory MESSAGE_TYPE = "Message(uint256 game,address to,bytes32 commitHash)";

        // hash to prevent signature collision
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(abi.encodePacked(EIP712_DOMAIN_TYPE)),
                keccak256(abi.encodePacked(name)),
                keccak256(abi.encodePacked(version)),
                chainId,
                verifyingContract
            )
        );

        // return signature address
        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01", // backslash is needed to escape the character
                    DOMAIN_SEPARATOR,
                    keccak256(
                        abi.encode(
                            keccak256(abi.encodePacked(MESSAGE_TYPE)),
                            _game,
                            _to,
                            _commitHash
                        )
                    )
                )
            ).recover(_signature);
    }
}
