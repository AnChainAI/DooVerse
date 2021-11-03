/**
 This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
**/
import NonFungibleToken from "../cadence/contracts/standard/NonFungibleToken.cdc"
import FungibleToken from "../cadence/contracts/standard/FungibleToken.cdc"
import CryptoPiggo from "./CryptoPiggo.cdc"

// What's the difference between this contract and the general-purpose 
// NFTStorefront contract?
//
//  1. Listings can now have a price of 0.
//
//  2. Only CryptoPiggo NFTs can be sold on the marketplace.
//
//  3. A CryptoPiggo can only be apart of ONE listing. Creating 
//     multiple listings for the same CryptoPiggo is not allowed.
//     However, each listing consists of an array of payment options 
//     which specifies the fungible tokens that can be used to purchase
//     the NFT along with other data such as the price and sale cut 
//     distribution.
//
//  4. Listing resource IDs have been replaced with CryptoPiggo IDs
//     for simplicity.
//
// Besides that, this contract is mostly the same. Each account that wants
// to list NFTs for sale installs a Storefront, and lists individual sales 
// within that Storefront as Listings. There is one Storefront per account, 
// it handles sales of CryptoPiggo NFTs ONLY for that account.
//
// Each Listing can have one or more "cut"s of the sale price that
// goes to one or more addresses. Cuts can be used to pay listing fees
// or other considerations.
// 
// Purchasers can watch for Listing events and check the NFT type and
// ID to see if they wish to buy the listed item.
// Marketplaces and other aggregators can watch for Listing events
// and list items of interest.
//
pub contract CryptoPiggoNFTStorefront {
  // NFTStorefrontInitialized
  // This contract has been deployed.
  // Event consumers can now expect events from this contract.
  //
  pub event NFTStorefrontInitialized()

  // StorefrontInitialized
  // A Storefront resource has been created.
  // Event consumers can now expect events from this Storefront.
  // Note that we do not specify an address: we cannot and should not.
  // Created resources do not have an owner address, and may be moved
  // after creation in ways we cannot check.
  // ListingAvailable events can be used to determine the address
  // of the owner of the Storefront (...its location) at the time of
  // the listing but only at that precise moment in that precise transaction.
  // If the seller moves the Storefront while the listing is valid, 
  // that is on them.
  //
  pub event StorefrontInitialized(storefrontResourceID: UInt64)

  // StorefrontDestroyed
  // A Storefront has been destroyed.
  // Event consumers can now stop processing events from this Storefront.
  // Note that we do not specify an address.
  //
  pub event StorefrontDestroyed(storefrontResourceID: UInt64)

  // ListingAvailable
  // A listing has been created and added to a Storefront resource.
  // The Address values here are valid when the event is emitted, but
  // the state of the accounts they refer to may be changed outside of the
  // NFTStorefront workflow, so be careful to check when using them.
  //
  pub event ListingAvailable(
    storefrontAddress: Address,
    nftID: UInt64,
    ftVaultTypes: [Type],
    prices: [UFix64]
  )

  // ListingCompleted
  // The listing has been resolved. It has either been purchased, or removed and destroyed.
  //
  pub event ListingCompleted(nftID: UInt64, storefrontResourceID: UInt64, purchased: Bool)

  // StorefrontStoragePath
  // The location in storage that a Storefront resource should be located.
  pub let StorefrontStoragePath: StoragePath

  // StorefrontPublicPath
  // The public location for a Storefront link.
  pub let StorefrontPublicPath: PublicPath


  // SaleCut
  // A struct representing a recipient that must be sent a certain amount
  // of the payment when a token is sold.
  //
  pub struct SaleCut {
    // The receiver for the payment.
    // Note that we do not store an address to find the Vault that this represents,
    // as the link or resource that we fetch in this way may be manipulated,
    // so to find the address that a cut goes to you must get this struct and then
    // call receiver.borrow()!.owner.address on it.
    // This can be done efficiently in a script.
    pub let receiver: Capability<&{FungibleToken.Receiver}>

    // The amount of the payment FungibleToken that will be paid to the receiver.
    pub let amount: UFix64

    // initializer
    //
    init(receiver: Capability<&{FungibleToken.Receiver}> , amount: UFix64) {
      self.receiver = receiver
      self.amount = amount
    }
  }

  // PaymentOption
  // A struct that stores payment information about a listing. One listing
  // can have many payment options. When a user purchases a listing, they 
  // must provide a payment vault that can be used to satisfy exactly one 
  // of the payment options for the listing.
  //
  pub struct PaymentOption {

    // The Type of the FungibleToken that payments must be made in.
    pub let salePaymentVaultType: Type

    // The amount that must be paid in the specified FungibleToken.
    pub let salePrice: UFix64

    // This specifies the division of payment between recipients.
    pub let saleCuts: [SaleCut]

    // initializer
    //
    init(
      salePaymentVaultType: Type,
      saleCuts: [SaleCut]
    ) {

      self.salePaymentVaultType = salePaymentVaultType

      // Store the cuts
      assert(saleCuts.length > 0, message: "Listing must have at least one payment cut recipient")
      self.saleCuts = saleCuts

      // Calculate the total price from the cuts
      var salePrice = 0.0
      // Perform initial check on capabilities, and calculate sale price from cut amounts.
      for cut in self.saleCuts {
        // Make sure we can borrow the receiver.
        // We will check this again when the token is sold.
        cut.receiver.borrow() ?? panic("Cannot borrow receiver")
        // Add the cut amount to the total price
        salePrice = salePrice + cut.amount
      }
      assert(salePrice >= 0.0, message: "Listing must have nonnegative price")

      // Store the calculated sale price
      self.salePrice = salePrice

    }
  }

  // ListingDetails
  // A struct containing a Listing's data.
  //
  pub struct ListingDetails {
    // The Storefront that the Listing is stored in.
    // Note that this resource cannot be moved to a different Storefront,
    // so this is OK. If we ever make it so that it *can* be moved,
    // this should be revisited.
    pub var storefrontID: UInt64
    // Whether this listing has been purchased or not.
    pub var purchased: Bool
    // The ID of the NFT within that type.
    pub let nftID: UInt64
    // An array of valid payment methods.
    pub let paymentOptions: [PaymentOption]

    // setToPurchased
    // Irreversibly set this listing as purchased.
    //
    access(contract) fun setToPurchased() {
      self.purchased = true
    }

    // initializer
    //
    init(
      nftID: UInt64,
      paymentOptions: [PaymentOption],
      storefrontID: UInt64
    ) {
      self.storefrontID = storefrontID
      self.purchased = false
      self.nftID = nftID
      self.paymentOptions = paymentOptions
    }
  }


  // ListingPublic
  // An interface providing a useful public interface to a Listing.
  //
  pub resource interface ListingPublic {
    // borrowNFT
    // This will assert in the same way as the NFT standard borrowNFT()
    // if the NFT is absent, for example if it has been sold via another listing.
    //
    pub fun borrowNFT(): & NonFungibleToken.NFT

    // purchase
    // Purchase the listing, buying the token.
    // This pays the beneficiaries and returns the token to the buyer.
    //
    pub fun purchase(payment: @FungibleToken.Vault): @NonFungibleToken.NFT

    // getDetails
    //
    pub fun getDetails(): ListingDetails
  }


  // Listing
  // A resource that allows an NFT to be sold for an amount of a given FungibleToken,
  // and for the proceeds of that sale to be split between several recipients.
  // 
  pub resource Listing: ListingPublic {
    // The simple (non-Capability, non-complex) details of the sale
    access(self) let details: ListingDetails

    // A capability allowing this resource to withdraw the NFT with the given ID from its collection.
    // This capability allows the resource to withdraw *any* NFT, so you should be careful when giving
    // such a capability to a resource and always check its code to make sure it will use it in the
    // way that it claims.
    access(contract) let nftProviderCapability: Capability<&{NonFungibleToken.Provider, NonFungibleToken.CollectionPublic}>

    // findValidPaymentOption
    // Finds a payment option that matches the given type and balance.
    access(self) fun findValidPaymentOption(vaultType: Type, balance: UFix64): PaymentOption? {
      for paymentOption in self.details.paymentOptions {
        if (
          vaultType == paymentOption.salePaymentVaultType && balance == paymentOption.salePrice
        ) {
          return paymentOption
        }
      }
      return nil
    }

    // borrowNFT
    // This will assert in the same way as the NFT standard borrowNFT()
    // if the NFT is absent, for example if it has been sold via another listing.
    //
    pub fun borrowNFT(): & NonFungibleToken.NFT {
      let ref = self.nftProviderCapability.borrow() !.borrowNFT(id: self.getDetails().nftID)
      //- CANNOT DO THIS IN PRECONDITION: "member of restricted type is not accessible: isInstance"
      //  result.isInstance(Type<@CryptoPiggo.NFT>()): "token has wrong type"
      assert(ref.isInstance(Type<@CryptoPiggo.NFT>()), message: "token has wrong type")
      assert(ref.id == self.getDetails().nftID, message: "token has wrong ID")
      return ref as & NonFungibleToken.NFT
    }

    // getDetails
    // Get the details of the current state of the Listing as a struct.
    // This avoids having more public variables and getter methods for them, and plays
    // nicely with scripts (which cannot return resources).
    //
    pub fun getDetails(): ListingDetails {
      return self.details
    }

    // purchase
    // Purchase the listing, buying the token.
    // This pays the beneficiaries and returns the token to the buyer.
    //
    pub fun purchase(payment: @FungibleToken.Vault): @NonFungibleToken.NFT {
      pre {
        self.details.purchased == false: "listing has already been purchased"
      }

      // Find a valid payment option
      let option = self.findValidPaymentOption(vaultType: payment.getType(), balance: payment.balance)
      if option == nil {
        panic("Could not find a valid payment option")
      }

      // Make sure the listing cannot be purchased again.
      self.details.setToPurchased()

      // Fetch the token to return to the purchaser.
      let nft <-self.nftProviderCapability.borrow() !.withdraw(withdrawID: self.details.nftID)
      // Neither receivers nor providers are trustworthy, they must implement the correct
      // interface but beyond complying with its pre/post conditions they are not gauranteed
      // to implement the functionality behind the interface in any given way.
      // Therefore we cannot trust the Collection resource behind the interface,
      // and we must check the NFT resource it gives us to make sure that it is the correct one.
      assert(nft.isInstance(Type<@CryptoPiggo.NFT>()), message: "withdrawn NFT is not of specified type")
      assert(nft.id == self.details.nftID, message: "withdrawn NFT does not have specified ID")

      // Rather than aborting the transaction if any receiver is absent when we try to pay it,
      // we send the cut to the first valid receiver.
      // The first receiver should therefore either be the seller, or an agreed recipient for
      // any unpaid cuts.
      var residualReceiver: &{FungibleToken.Receiver}? = nil

      // Pay each beneficiary their amount of the payment.
      for cut in option!.saleCuts {
        if let receiver = cut.receiver.borrow() {
          let paymentCut <-payment.withdraw(amount: cut.amount)
          receiver.deposit(from: <-paymentCut)
          if (residualReceiver == nil) {
            residualReceiver = receiver
          }
        }
      }

      assert(residualReceiver != nil, message: "No valid payment receivers")

      // At this point, if all recievers were active and availabile, then the payment Vault will have
      // zero tokens left, and this will functionally be a no-op that consumes the empty vault
      residualReceiver!.deposit(from: <-payment)

      // If the listing is purchased, we regard it as completed here.
      // Otherwise we regard it as completed in the destructor.
      emit ListingCompleted(
        nftID: self.details.nftID,
        storefrontResourceID: self.details.storefrontID,
        purchased: self.details.purchased
      )

      return <-nft
    }

    // destructor
    //
    destroy() {
      // If the listing has not been purchased, we regard it as completed here.
      // Otherwise we regard it as completed in purchase().
      // This is because we destroy the listing in Storefront.removeListing()
      // or Storefront.cleanup() .
      // If we change this destructor, revisit those functions.
      if !self.details.purchased {
        emit ListingCompleted(
          nftID: self.details.nftID,
          storefrontResourceID: self.details.storefrontID,
          purchased: self.details.purchased
        )
      }
    }

    // initializer
    //
    init(
      nftProviderCapability: Capability<&{NonFungibleToken.Provider, NonFungibleToken.CollectionPublic}>,
      nftID: UInt64,
      paymentOptions: [PaymentOption],
      storefrontID: UInt64
    ) {
      // Store the sale information
      self.details = ListingDetails(
        nftID: nftID,
        paymentOptions: paymentOptions,
        storefrontID: storefrontID
      )

      // Store the NFT provider
      self.nftProviderCapability = nftProviderCapability

      // Check that the provider contains the NFT.
      // We will check it again when the token is sold.
      // We cannot move this into a function because initializers cannot call member functions.
      let provider = self.nftProviderCapability.borrow()
      assert(provider != nil, message: "cannot borrow nftProviderCapability")

      // This will precondition assert if the token is not available.
      let nft = provider!.borrowNFT(id: self.details.nftID)
      assert(nft.isInstance(Type<@CryptoPiggo.NFT>()), message: "token is not of specified type")
      assert(nft.id == self.details.nftID, message: "token does not have specified ID")
    }
  }

  // StorefrontManager
  // An interface for adding and removing Listings within a Storefront,
  // intended for use by the Storefront's own
  //
  pub resource interface StorefrontManager {
    // createListing
    // Allows the Storefront owner to create and insert Listings.
    //
    pub fun createListing(
      nftProviderCapability: Capability<&{NonFungibleToken.Provider, NonFungibleToken.CollectionPublic}>,
      nftID: UInt64,
      paymentOptions: [PaymentOption],
    ): UInt64
    // removeListing
    // Allows the Storefront owner to remove any sale listing, acepted or not.
    //
    pub fun removeListing(nftID: UInt64)
  }

  // StorefrontPublic
  // An interface to allow listing and borrowing Listings, and purchasing items via Listings
  // in a Storefront.
  //
  pub resource interface StorefrontPublic {
    pub fun getListingIDs(): [UInt64]
    pub fun borrowListing(nftID: UInt64): &Listing{ListingPublic}?
    pub fun cleanup(nftID: UInt64)
  }

  // Storefront
  // A resource that allows its owner to manage a list of Listings, and anyone to interact with them
  // in order to query their details and purchase the NFTs that they represent.
  //
  pub resource Storefront: StorefrontManager, StorefrontPublic {
    // The dictionary of NFT IDs to Listing resources.
    access(self) var listings: @{UInt64: Listing}

    // insert
    // Create and publish a Listing for an NFT.
    //
    pub fun createListing(
      nftProviderCapability: Capability<&{NonFungibleToken.Provider, NonFungibleToken.CollectionPublic}>,
      nftID: UInt64,
      paymentOptions: [PaymentOption],
    ): UInt64 {
      pre {
        !self.listings.containsKey(nftID): "NFT is already listed for sale."
      }

      let listing <-create Listing(
        nftProviderCapability: nftProviderCapability,
        nftID: nftID,
        paymentOptions: paymentOptions,
        storefrontID: self.uuid
      )

      // Add the new listing to the dictionary.
      let oldListing <-self.listings[nftID] <-listing
      // Note that oldListing will always be nil, but we have to handle it.
      destroy oldListing

      // Collect vault types and their corresponding prices
      let vaultTypes: [Type] = []
      let prices: [UFix64] = []
      for paymentOption in paymentOptions {
        vaultTypes.append(paymentOption.salePaymentVaultType)
        prices.append(paymentOption.salePrice)
      }

      emit ListingAvailable(
        storefrontAddress: self.owner?.address!,
        nftID: nftID,
        ftVaultTypes: vaultTypes,
        prices: prices
      )

      return nftID
    }

    // removeListing
    // Remove a Listing that has not yet been purchased from the collection and destroy it.
    //
    pub fun removeListing(nftID: UInt64) {
      let listing <-self.listings.remove(key: nftID) ??
        panic("missing Listing")

      // This will emit a ListingCompleted event.
      destroy listing
    }

    // getListingIDs
    // Returns an array of the Listing resource IDs that are in the collection
    //
    pub fun getListingIDs(): [UInt64] {
      return self.listings.keys
    }

    // borrowSaleItem
    // Returns a read-only view of the SaleItem for the given listingID if it is contained by this collection.
    //
    pub fun borrowListing(nftID: UInt64): &Listing{ListingPublic}? {
      if self.listings[nftID] != nil {
        return &self.listings[nftID] as! &Listing{ListingPublic}
      } else {
        return nil
      }
    }

    // cleanup
    // Remove an listing *if* it has been purchased.
    // Anyone can call, but at present it only benefits the account owner to do so.
    // Kind purchasers can however call it if they like.
    //
    pub fun cleanup(nftID: UInt64) {
      pre {
        self.listings[nftID] != nil: "could not find listing with given id"
      }

      let listing <-self.listings.remove(key: nftID) !
        assert(listing.getDetails().purchased == true, message: "listing is not purchased, only admin can remove")
      destroy listing
    }

    // destructor
    //
    destroy() {
      destroy self.listings

      // Let event consumers know that this storefront will no longer exist
      emit StorefrontDestroyed(storefrontResourceID: self.uuid)
    }

    // constructor
    //
    init() {
      self.listings <-{}

      // Let event consumers know that this storefront exists
      emit StorefrontInitialized(storefrontResourceID: self.uuid)
    }
  }

  // createStorefront
  // Make creating a Storefront publicly accessible.
  //
  pub fun createStorefront(): @Storefront {
    return <-create Storefront()
  }

  init() {
    self.StorefrontStoragePath = /storage/NFTStorefront
    self.StorefrontPublicPath = /public/NFTStorefront

    emit NFTStorefrontInitialized()
  }
}