/***********************
* Lines 6 to 42 is ForkOracle.sol
* Lines 42 onwards is HistoryRevison.sol
* ***********************/

// ForkOracle.sol Contract: 
pragma solidity ^0.4.10;

// Oracle: Only release coins (return true) if the balance of A1 is 0 and the balance of A2 is c.

contract ForkOracle {

  address public a1; // Empty this account
  address public a2; // Has 'c' coins
  uint public height; // Balance must be valid at this block height
  uint public c; // No of coins 

  // Set up our fork oracle conditions
  function ForkOracle(address _a1, address _a2, uint _c, uint _height) {
    a1 = _a1;
    a2 = _a2;
    c = _c;
    height = _height;
  }

  // release bribe if condition is satisified
  function releaseBribe() returns (bool) {

    // Has A2 received the coins from A1?
    // Why is this important? By sending all coins to A2....
    // All future transactions by A1 are invalidated (it no longer has any coins to spend)
    // Sure - someone can fund A1 and broadcast its transactions (if the nonce allows),
    // But that isn't A1 anymore - furthermore if A1 is a contract - it can selfdestruct too
    if(a1.balance == 0 && a2.balance == c && height == block.number) {
      return true;
    }

    return false;
  }


}

// HistoryRevision.sol Contract

pragma solidity ^0.4.10;

// Idea: This is the interface to a fork oracle contract.
// We only need to know about the "releaseBribe()" method - that returns true
// if we are in the desired fork (i.e. we can release the bribe) or returns false
// if we are not in the desired fork (i.e. we cant release the bribe).
contract ForkOracle {

  function releaseBribe() returns (bool); // Returns true if bribe can be released.
}

// Idea: Allows a miner to perform a double-spend attack and leverage the uncle reward policy
// to subsidise this attack!
contract HistoryRevisionCon {

  mapping(bytes32 => bool) public paid_uncleblocks; // Bribe processed for this uncle block
  mapping(uint => bool) public paid_mainblocks; // Bribe processed for this main block
  address public owner;
  uint public blockreward = 3; // Reduced to 3 ince the new hardfork
  uint public incentive = 1;
  uint public unclehistory = 8;
  uint public deposit = 0;
  bytes32 public startingblock = 0;
  uint public blockheight = 0;
  bool public activated = false;

  // Illustration Only.
  struct BlockHeader {
    uint number;
    bytes32 previous_blockhash;
    address coinbase;
    BlockHeader[] uncleblocks;
  }

  function HistoryRevisionCon() {
    owner = msg.sender;
  }

  function deposit() {
    if(msg.sender != owner) { throw; }
    deposit = deposit + msg.value;
  }

  // Signed message from owner of contract to activate the alt fork!
  function activate(uint _blockheight, uint _incentive, address _oracle, uint _bal, uint8 v, bytes32 r, bytes32 s) {
    bytes32 h = sha3(_blockheight, _incentive, _oracle, _bal);
    address signer = ecrecover(h, v, r, s);

    // Check that msg.sender is the same person from the signed message!
    // Briber signs from this account - such that any previous transaction is reversed (due to high counter)
    if(msg.sender != owner) { return false; }

    // Fetch our oracle!
    ForkOracle oracle = new ForkOracle(_oracle);
    // Signer of message is the briber, activating this contract on desired block height, and
    // the forking condition (i.e. addr has the desired balance) is satisfied.
    if(signer == owner && block.number == _blockheight && oracle.releaseBribe()) {
      blockheight = _blockheight;
      incentive = _incentive;
      activated = true;

      // Block we are extending for the fork's first block
      // We should not reward any blocks mined BEFORE this one!
      startingblock = block.blockhash(block.number-1);
    }
  }

  // Accept bribe if you mined this block!
  function acceptBribe() {
    if(!activated) { return false; }
    if(block.coinbase != msg.sender) {return;} // Must be miner

    // Must be after main's desired block height
    // AND can only be claimed once!
    if(block.number >= _blockheight && !paid_mainblocks[block.number]) {
      paid_mainblocks[block.number] = true;
      msg.sender.send(incentive); // Send money to miner!

    }
  }

  // Not implemented. Only here for illustration.
  function bytesToBlockHeader(bytes header) returns (BlockHeader);

  // Subsidise all uncle blocks!
  // How do we ensure these block headers are authenticate?
  // We check for the hash of main and publisher using block.blockhash (and hash the headers given to us)
  // We also check that publisher contains the full block header for uncle! (and that is part of its block hash).
  function acceptBribe(bytes _main, bytes _uncle, bytes _publisher) {

    // Compute block headers
    BlockHeader memory main = bytesToBlockHeader(_main);
    BlockHeader memory uncle = bytesToBlockHeader(_uncle);
    BlockHeader memory publisher = bytesToBlockHeader(_publisher);

    // Set starting block (if not set already)!
    if(!activated) { return false; }

    // Confirm this block has not been processed
    if(paid_uncleblocks[sha3(uncle)]) { return false; }

    // Confirm that both the main and uncle block extend the same sibiling.
    if(main.previous_blockhash != uncle.previous_blockhash) {return false; }

    // Look for uncle block
    bool uncle_found = false;
    for(i=0; i<publisher.uncleblocks.length; i++) {
      BlockHeader publisher_uncle = publisher.uncleblocks[i];
      if(publisher_uncle == uncle) {
        uncle_found = true;
        break;
      }
    }

    // Was uncle found in publisher?
    if(uncle_found) {
      // Yes - then the block must be valid!
      bool foundMain = false; uint mainPOS = 0;
      bool foundPublisher = false; uint publisherPOS = 0;

      // Lets make sure that both main and publisher are in the blockchain
      for(uint i=block.number; i>=block.number-256; i--) {
        if(foundmain && foundPublisher) { break; } // Stop looping once both are found
        bytes32 h = block.blockhash(i);

        // We cannot pay for uncles prior to the starting blocks!
        // Also means we won't pay for uncles that mined blocks prior to this block
        // As both the "main" and "uncle" must extend the same block hash!
        if(h == startingblock) {return false;}

        // Found main's block hash?
        if(h == sha3(main) && !foundmain) {
          foundmain = true;
          mainPOS = i;
        }

        // Found publisher's block hash?
        if(h == sha3(publisher) && !foundPublisher) {
          foundPublisher = true;
          publisherPOS = i;
        }

      }

      // Sanity check... make sure main < publisher...
      if(mainPOS >= publisherPOS) { return false; }

      // Compute Reward
      uint distance = mainPOS - publisherPOS;

      // Only pay the uncle miner if it is a recent uncle block...
      if(distance < unclehistory) {
        // reward = 5 * (8-d)/8
        uint reward = blockreward * ((unclehistory-distance)/unclehistory);
        reward = blockreward - reward; // Compute the subsidy
        paid_uncleblocks[sha3(uncle)] = true;
        uncle.coinbase.send(reward + incentive);
      }
    }
  }
}
