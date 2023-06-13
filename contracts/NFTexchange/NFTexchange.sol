// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./Lib/LibAsset.sol";
import "./Lib/LibTransfer.sol";
import "./Lib/MarketOwner.sol";
import "./Lib/Order.sol";
import "./Lib/State.sol";
import "./Lib/Validate.sol";
import "./Lib/interface/ITransferManager.sol";
import "./Lib/interface/IOrder.sol";
import "../royalties/IERC2981Royalties.sol";


contract NFTexchange is ReentrancyGuard, Validate, MarketOwner {
  
  using Counters for Counters.Counter;
  using SafeMath for uint256;
  Counters.Counter private _itemCounter; //start from 1
  Counters.Counter private _itemSoldCounter;
  Counters.Counter private _itemBidCounter;
  IERC2981Royalties royalties;
      
  using LibTransfer for address;

  mapping(uint256 => Order.OrderItem) public orderItems;
  mapping(uint256 => BidList) public bidItems;


   struct BidList {
    uint id;
    uint marketItemId;
    LibAsset.Asset sellerAsset;
    LibAsset.Asset buyerAsset;
    address bidder;
    address seller;
    bool isAccepted;
   }

  event MarketItemCreated (
    uint indexed id,
    address seller,
    LibAsset.Asset sellerAsset,
    address buyer,
    LibAsset.Asset buyerAsset,
    uint start,
    uint end,
    State.stateItem state
  );

   event bidToItem (
    uint indexed id,
    LibAsset.Asset sellerAsset,
    LibAsset.Asset buyerAsset,
    address bidder,
    address seller,
    bool isAccepted
  );

  event MarketItemSold (
    uint indexed id,
    address seller,
    LibAsset.Asset sellerAsset,
    address buyer,
    LibAsset.Asset buyerAsset,
    State.stateItem state
  );

   function createMarketItem(
     LibAsset.Asset memory _sellerAsset,
     LibAsset.Asset memory _buyerAsset,
     uint _start,
     uint _end
   ) public {

     Order.isApproved(_sellerAsset);

     _itemCounter.increment();
     uint256 id = _itemCounter.current();

     orderItems[id] = Order.OrderItem(
      id,
      payable(msg.sender),
      _sellerAsset,
      payable(address(0)),
      _buyerAsset,
      _start,
      _end,
      State.stateItem.Created
     );
    
    emit MarketItemCreated(
      id,
      msg.sender,
      _sellerAsset,
      address(0),
      _buyerAsset,
      _start,
      _end,
      State.stateItem.Created
    );
  }  


  function checkStatusItem(Order.OrderItem memory _order) private view {
    require(orderItems[_order.id].state == State.stateItem.Created, "You can't interact with this order");
  }
  

  function deleteMarketItem(uint256 itemId) public nonReentrant {
    require(itemId <= _itemCounter.current(), "id must <= item count");
    require(orderItems[itemId].state == State.stateItem.Created, "item must be on market");
    Order.OrderItem storage item = orderItems[itemId];
    (address token, uint tokenId) = abi.decode(item.sellerAsset.assetType.data, (address, uint));

    if(item.sellerAsset.assetType.assetClass == LibAsset.ERC721_ASSET_CLASS){
      require(IERC721(token).ownerOf(tokenId) == msg.sender, "must be the owner");
      require(IERC721(token).isApprovedForAll(msg.sender, address(this)), "NFT must be approved to market");
    }else if(item.sellerAsset.assetType.assetClass == LibAsset.ERC1155_ASSET_CLASS) {
      require(item.sellerAsset.value <= IERC1155(token).balanceOf(msg.sender, tokenId), "You don't have amount enough of this token");
      require(IERC1155(token).isApprovedForAll(msg.sender, address(this)), "NFT must be approved to market");
    }
    
    item.state = State.stateItem.Inactive;

    emit MarketItemSold(
      itemId,
      item.seller,
      item.sellerAsset,
      msg.sender,
      item.buyerAsset,
      State.stateItem.Release
    );

  }

  function marketSale(uint256 marketItemId) public payable nonReentrant  {
    Order.OrderItem storage item = orderItems[marketItemId];
    checkStatusItem(item);
    validateOrder(item);
    LibAsset.Asset memory matchNFT = item.sellerAsset;
    require(matchNFT.assetType.assetClass == LibAsset.ERC1155_ASSET_CLASS || matchNFT.assetType.assetClass == LibAsset.ERC721_ASSET_CLASS, "Asset type is invalid");
      // Order.isApproved(matchNFT);
      doTransfer(item);
      item.state = State.stateItem.Release;
      _itemSoldCounter.increment(); 
      item.buyer = payable(msg.sender);

      emit MarketItemSold(
        marketItemId,
        item.seller,
        item.sellerAsset,
        msg.sender,
        item.buyerAsset,
        State.stateItem.Release
      ); 
  } 



   function doTransfer(Order.OrderItem memory order) private {
        LibAsset.Asset memory buyerAsset = order.buyerAsset;
        LibAsset.Asset memory sellerAsset = order.sellerAsset;
        (address token, uint tokenId) = abi.decode(sellerAsset.assetType.data, (address, uint));
        (address buyToken) = abi.decode(buyerAsset.assetType.data, (address));

        if(sellerAsset.assetType.assetClass == LibAsset.ERC721_ASSET_CLASS){
           IERC721(token).safeTransferFrom(order.seller, msg.sender, tokenId);
        }else if(sellerAsset.assetType.assetClass == LibAsset.ERC1155_ASSET_CLASS){
           IERC1155(token).safeTransferFrom(order.seller, msg.sender, tokenId, sellerAsset.value,
           "0x00");
        }

        (address royaltyReciever, uint royaltyValue) = IERC2981Royalties(token).royaltyInfo(tokenId, sellerAsset.value);
        
        if(buyerAsset.assetType.assetClass == LibAsset.ERC20_ASSET_CLASS){
          checkBalanceERC20(buyToken, buyerAsset.value, msg.sender);
           uint256 priceWithRoyalty = buyerAsset.value.sub(royaltyValue);
           uint256 finalCost = priceWithRoyalty.sub(protcolfee);
           TransferFeeMarketOwner(buyerAsset);
           IERC20(buyToken).transferFrom(msg.sender, order.seller, finalCost);
           IERC20(buyToken).transferFrom(msg.sender, royaltyReciever, royaltyValue);
        }else if(buyerAsset.assetType.assetClass == LibAsset.ETH_ASSET_CLASS) {
           require(msg.value > 0, "wei can't be zero");
           require(msg.value >= buyerAsset.value, "you don't have ether enough");
           uint256 priceWithRoyalty = buyerAsset.value - royaltyValue;
           uint256 finalCost = priceWithRoyalty.sub(protcolfee);
           TransferFeeMarketOwner(buyerAsset);
           address(order.seller).transferEth(finalCost);
           address(royaltyReciever).transferEth(royaltyValue);
        }
   }

   function checkRoyalty(address token, uint256 tokenId, uint256 price) public view returns(address, uint) {
      (address royaltyReciever, uint royaltyValue) = IERC2981Royalties(token).royaltyInfo(tokenId, price);
      return (royaltyReciever, royaltyValue);
   }

    function setBid(BidList memory _bidItem) public {
        Order.OrderItem storage marketitem = orderItems[_bidItem.marketItemId];
        require(_bidItem.marketItemId == marketitem.id , "Not found this item in market");
        validateOrder(marketitem);
        _itemBidCounter.increment();
        uint256 id = _itemBidCounter.current();

        bidItems[id] = BidList(
          id,
          marketitem.id,
          marketitem.sellerAsset,
          marketitem.buyerAsset,
          address(msg.sender),
          marketitem.seller,
          false
        );

        emit bidToItem(
        id,
        marketitem.sellerAsset,
        marketitem.buyerAsset,  
        address(msg.sender),
        marketitem.seller,
        false
        );
    }

    function getTotalBids() public view returns (uint256) { return _itemBidCounter.current(); }

    function acceptBidByOwner(uint256 _bidItemId) public {
        BidList storage Biditem = bidItems[_bidItemId];
        Order.OrderItem storage marketitem = orderItems[Biditem.marketItemId];

        (address token, uint tokenId) = abi.decode(Biditem.sellerAsset.assetType.data, (address, uint));
        (address buyToken, uint price) = abi.decode(Biditem.buyerAsset.assetType.data, (address, uint));

        require(IERC721(token).ownerOf(tokenId) == address(msg.sender) , "you should be owner this token id");
        require(IERC721(token).isApprovedForAll(msg.sender, address(this)), "NFT must be approved to market");
        checkBalanceERC20(buyToken, price, address(Biditem.bidder));

        (address receiver, uint royalityAmount) = royalties.royaltyInfo(tokenId, price);
    
        IERC721(token).transferFrom(msg.sender, Biditem.bidder, tokenId);
    
        uint cost = price.sub(royalityAmount);
        IERC20(buyToken).transferFrom(Biditem.bidder, receiver, royalityAmount);
        IERC20(buyToken).transferFrom(Biditem.bidder, marketitem.seller, cost);

        marketitem.buyer = payable(Biditem.bidder);
        marketitem.state = State.stateItem.Release;
        _itemSoldCounter.increment();   
        Biditem.isAccepted = true; 

        emit MarketItemSold(
        marketitem.id,
        marketitem.seller,
        marketitem.sellerAsset,
        msg.sender,
        marketitem.buyerAsset,
        State.stateItem.Release
      ); 
    }

}
