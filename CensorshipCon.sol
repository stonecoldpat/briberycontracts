pragma solidity ^0.4.10;

// Idea: Briber wants full control over the blockchain.
// He publicly pledges "if you do not broadcast your blocks until my block is in the blockchain,
// then BriberyCon will reward you!".
// He creates this contract and deposits ether into it.
// All miners are guaranteed this payment due to the contract's enforcement

// This is an ILLUSTRATION of how the contract might work in practice.
// We have not implemented the logic to parse Ethereum block headers.

contract CensorshipCon {

  address public owner; // Briber's address
  mapping(bytes32 => bool) public paid; // Bribe processed for this uncle block
  uint public blockreward = 5; // Ether sent to miner of a block
  uint public unclehistory = 8; // Unlce blocks are only rewarded up to this distance
  uint public bribe; // Extra ether sent per block
  uint public deposit;   // Briber's full deposit


  // Illustration Only.
  struct BlockHeader {
    bytes32 blockhash; // hash for this block
    bytes32 previous_blockhash; // hash of prebvious block
    address coinbase; // owner of this block
    BlockHeader[] uncleblocks; // list of uncle block headers included in this block
  }

  // Only owner of this contract can update deposit 
  function deposit() {
    if(msg.sender != owner) { return false; }
    deposit = deposit + msg.value;
  }

  // Not implemented. Only here for illustration.
  function bytesToBlockHeader(bytes header) returns (BlockHeader);

  // Provided the briber's block header, bribed uncle block header, and publisher block
  // We can work out if the bribed miner did indeed withhold a valid block
  // and wait for it to be accepted as an uncle block.
  // If so, we compute the uncle reward he received, and then pay him the rest of our bribe.
  function acceptBribe(bytes _briber, bytes _bribed, bytes _publisher) {

    // Compute block headers
    BlockHeader memory briber = bytesToBlockHeader(_briber);
    BlockHeader memory bribed = bytesToBlockHeader(_bribed);
    BlockHeader memory publisher = bytesToBlockHeader(_publisher);

     // Confirm this block has not been processed
    if(paid[bribed.blockhash]) { return false; }

    // Confirm that both the briber and bribed blocks extend the same sibiling.
    if(briber.previous_blockhash != bribed.previous_blockhash) {return false;}

    // Confirm the bribed block was mined by the briber
    // Worth assuming briber creates a new address throughout this attack
    // To stop old blocks being accepted here.
    if(briber.coinbase != owner) { return false; }

    // Look for uncle block!
    bool uncle_found = false;
    for(i=0; i<publisher.uncleblocks.length; i++) {
      BlockHeader publisher_uncle = publisher.uncleblocks[i];
      if(publisher_uncle == bribed) {
        uncle_found = true;
        break;
      }
    }

    // Is bribed a real uncle block for publisher?
    if(uncle_found) {

      // Yes - then check briber's block and publisher block is in the blockchain.
      bool foundBriber = false;
      uint briberPOS = 0;
      bool foundPublisher = false;
      uint publisherPOS = 0;

      // Lets make sure that both briber and publisher are in the blockchain
      for(uint i=256; i>=0; i--) {
        if(foundBriber && foundPublisher) { break; } // Stop looping once both are found
        bytes32 h = block.blockhash(i);

        // We do not have to make sure this is a super old block
        // If we assume briber starts using a unique address
        // From the start of this attack.
        // As that essentially acts as a "checkpoint"

        // Found briber's block hash?
        if(h == briber.blockhash && !foundBriber) { foundBriber = true; briberPOS = i; }
        // Found publisher's block hash?
        if(h == publisher.blockhash && !foundPublisher) { foundPublisher = true; publisherPOS = i;}
      }

      // Compute Reward
      uint distance = briberPOS - publisherPOS;

      // Only pay the bribed miner if it is a recent uncle block...
      // Also make sure briber block is older than publisher...
      if(briberPOS < publisherPOS && distance <= unclehistory) {
        //   reward = 5 * (8-d)/8
        uint unclereward = blockreward * ((unclehistory-distance)/unclehistory);
        uint remaining_to_pay = blockreward - reward; // Compute the subsidy
        paid[bribed.blockhash] = true;
        sendReward(bribed.coinbase, remaining_to_pay + bribe);
      }
    }
  }
}
