import DBNonFungibleToken from "./DBNonFungibleToken.cdc"

// Doosan Bear Collectable!
//
pub contract DBCollectable: DBNonFungibleToken {

    // Events
    //
    pub event ContractInitialized()
    pub event Withdraw(id: UInt64, from: Address?,trxMeta: {String: String})
    pub event Deposit(id: UInt64, to: Address?,trxMeta: {String: String})
    pub event Minted(id: UInt64, initMeta: {String: String})

    // Named Paths
    //
    pub let CollectionStoragePath: StoragePath
    pub let CollectionPublicPath: PublicPath
    pub let MinterStoragePath: StoragePath

    // totalSupply
    // The total number of DBCollectable that have been minted
    //
    pub var totalSupply: UInt64

    // NFT
    // A Doosan Bears Collectable as an NFT
    //
    pub resource NFT: DBNonFungibleToken.INFT {
        // The token's ID
        pub let id: UInt64
        // The token's metadata in dict format
        pub var metaData: {String: String}

        // initializer
        //
        init(initID: UInt64, initMeta: {String: String}) {
            self.id = initID
            self.metaData = initMeta
        }
    }

    // This is the interface that users can cast their DBCollectable Collection as
    // to allow others to deposit DBCollectable into their Collection. It also allows for reading
    // the details of DBCollectable in the Collection.
    pub resource interface DBCollectableCollectionPublic {
        pub fun deposit(token: @DBNonFungibleToken.NFT,trxMeta: {String: String})
        pub fun getIDs(): [UInt64]
        pub fun borrowNFT(id: UInt64): &DBNonFungibleToken.NFT
        pub fun borrowDoosanBearCollectable(id: UInt64): &DBCollectable.NFT? {
            // If the result isn't nil, the id of the returned reference
            // should be the same as the argument to the function
            post {
                (result == nil) || (result?.id == id):
                    "Cannot borrow DoosanBearCollectable reference: The ID of the returned reference is incorrect"
            }
        }
    }

    // Collection
    // A collection of DoosanBearCollectable NFTs owned by an account
    //
    pub resource Collection: DBCollectableCollectionPublic, DBNonFungibleToken.Provider, DBNonFungibleToken.Receiver, DBNonFungibleToken.CollectionPublic {
        // dictionary of NFT conforming tokens
        // NFT is a resource type with an `UInt64` ID field
        //
        pub var ownedNFTs: @{UInt64: DBNonFungibleToken.NFT}

        // withdraw
        // Removes an NFT from the collection and moves it to the caller
        //
        pub fun withdraw(withdrawID: UInt64, trxMeta: {String: String}): @DBNonFungibleToken.NFT {
            let token <- self.ownedNFTs.remove(key: withdrawID) ?? panic("missing NFT")

            emit Withdraw(id: token.id, from: self.owner?.address,trxMeta: trxMeta)

            return <-token
        }

        // deposit
        // Takes a NFT and adds it to the collections dictionary
        // and adds the ID to the id array
        //
        pub fun deposit(token: @DBNonFungibleToken.NFT, trxMeta: {String: String}) {
            let token <- token as! @DBCollectable.NFT

            let id: UInt64 = token.id

            // add the new token to the dictionary which removes the old one
            let oldToken <- self.ownedNFTs[id] <- token

            emit Deposit(id: id, to: self.owner?.address,trxMeta:trxMeta)

            destroy oldToken
        }

        // getIDs
        // Returns an array of the IDs that are in the collection
        //
        pub fun getIDs(): [UInt64] {
            return self.ownedNFTs.keys
        }

        // borrowNFT
        // Gets a reference to an NFT in the collection
        // so that the caller can read its metadata and call its methods
        //
        pub fun borrowNFT(id: UInt64): &DBNonFungibleToken.NFT {
            return &self.ownedNFTs[id] as &DBNonFungibleToken.NFT
        }

        // borrowDoosanBearCollectable
        // Gets a reference to an NFT in the collection as a DoosanBearCollectable,
        // exposing all of its fields (including the typeID).
        // This is safe as there are no functions that can be called on the DoosanBearCollectable.
        //
        pub fun borrowDoosanBearCollectable(id: UInt64): &DBCollectable.NFT? {
            if self.ownedNFTs[id] != nil {
                let ref = &self.ownedNFTs[id] as auth &DBNonFungibleToken.NFT
                return ref as! &DBCollectable.NFT
            } else {
                return nil
            }
        }

        // destructor
        destroy() {
            destroy self.ownedNFTs
        }

        // initializer
        //
        init () {
            self.ownedNFTs <- {}
        }
    }

    // createEmptyCollection
    // public function that anyone can call to create a new empty collection
    //
    pub fun createEmptyCollection(): @DBNonFungibleToken.Collection {
        return <- create Collection()
    }

    // NFTMinter
    // Resource that an admin or something similar would own to be
    // able to mint new NFTs
    //
	pub resource NFTMinter {

		// mintNFT
        // Mints a new NFT with a new ID
		// and deposit it in the recipients collection using their collection reference
        //
		pub fun mintNFT(recipient: &{DBNonFungibleToken.CollectionPublic}, initMeta: {String: String},trxMeta: {String: String}) {
            emit Minted(id: DBCollectable.totalSupply, initMeta: initMeta)

			// deposit it in the recipient's account using their reference
			recipient.deposit(token: <-create DBCollectable.NFT(initID: DBCollectable.totalSupply,initMeta: initMeta ),trxMeta: trxMeta)

            DBCollectable.totalSupply = DBCollectable.totalSupply + (1 as UInt64)
		}
	}

    // fetch
    // Get a reference to a DoosanBearCollectable from an account's Collection, if available.
    // If an account does not have a DBCollectable.Collection, panic.
    // If it has a collection but does not contain the itemId, return nil.
    // If it has a collection and that collection contains the itemId, return a reference to that.
    //
    pub fun fetch(_ from: Address, itemID: UInt64): &DBCollectable.NFT? {
        let collection = getAccount(from)
            .getCapability(DBCollectable.CollectionPublicPath)
            .borrow<&DBCollectable.Collection{DBCollectable.DBCollectableCollectionPublic}>()                                                        
            ?? panic("Couldn't get collection")
        // We trust DBCollectable.Collection.borowDoosanBearCollectable to get the correct itemID
        // (it checks it before returning it).
        return collection.borrowDoosanBearCollectable(id: itemID)
    }

    // initializer
    //
	init() {
        // Set our named paths
        self.CollectionStoragePath = /storage/DBCollectableCollection001
        self.CollectionPublicPath = /public/DBCollectableCollection001
        self.MinterStoragePath = /storage/DBCollectableMinter001

        // Initialize the total supply
        self.totalSupply = 0

        // Create a Minter resource and save it to storage
        let minter <- create NFTMinter()
        self.account.save(<-minter, to: self.MinterStoragePath)

        emit ContractInitialized()
	}
}
