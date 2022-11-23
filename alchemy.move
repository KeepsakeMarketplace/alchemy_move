module nfts::alchemy {
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::dynamic_object_field as ofield;
    use std::vector;
    
    use nft_protocol::collection::{MintAuthority};
    use nft_protocol::std_collection::{Self};
    use nft_protocol::collectible::{Self, Collectible};
    use nft_protocol::nft::{Self, Nft};

    const U64_MAX: u64 = 18446744073709551615;
    const AuthorityKey: u64 = 0;
    /// The type identifier of the NFT. The NFTs will have a type
    /// tag of kind: `Coin<package_object::mycoin::MYCOIN>`
    ///Name must not match the module name, as one time witnesses cannot be stored.
    struct ELEMENTS has store, drop {}
    struct NFTCarrier has key { id: UID, nft: ELEMENTS }
    struct BaseData has key {
        id: UID, 
        elements: vector<ID>,
        admin: address,
    }

    struct Combination has key, store {
        id: UID, 
        from1: ID,
        from2: ID,
        to: ID
    }

    const EWrongCombination: u64 = 546730;
    const EBasicNotFound: u64 = 546731;
    const EBasicExists: u64 = 546732;
    const EUnauthorized: u64 = 546733;

    // collection is created later so we can pass in parameters
    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            NFTCarrier { id: object::new(ctx), nft: ELEMENTS {} },
            tx_context::sender(ctx)
        );
        transfer::share_object(BaseData { id: object::new(ctx), admin: tx_context::sender(ctx), elements: vector::empty<ID>() })
    }

    /// Can only be called once thanks to the transferrable one time witness
    public entry fun create(
        royalty_receiver: address,
        tags: vector<vector<u8>>,
        royalty_fee_bps: u64,
        json: vector<u8>,
        carrier: NFTCarrier,
        ctx: &mut TxContext,
    ) {
        let NFTCarrier { id, nft: _ } = carrier;
        object::delete(id);

        std_collection::mint<ELEMENTS>(
            b"Keepsake Alchemy", // name
            b"A NFT collection of elements", // description
            b"KSAL", // symbol
            0, // max_supply
            royalty_receiver, // Royalty receiver
            tags, // tags
            royalty_fee_bps, // royalty_fee_bps
            true, // is_mutable
            json, // json field, unknown use?
            tx_context::sender(ctx), // recipient
            ctx,
        );
    }

    // Once the collection is created, we then give the MintAuthority to the shared BaseData, so any user can mint NFTs
    public entry fun share_mint(baseData: &mut BaseData, authority: MintAuthority<ELEMENTS>) {
        ofield::add(&mut baseData.id, AuthorityKey, authority);
    }

    // creates collectible data for an element (think of it as a blueprint or a mould)
    public entry fun mint_data(
        name: vector<u8>,
        description: vector<u8>,
        url: vector<u8>,
        attribute_keys: vector<vector<u8>>,
        attribute_values: vector<vector<u8>>,
        baseData: &mut BaseData,
        ctx: &mut TxContext,
    ){
        assert!(tx_context::sender(ctx) == baseData.admin, EUnauthorized);
        let authority = ofield::borrow_mut<u64, MintAuthority<ELEMENTS>>(&mut baseData.id, AuthorityKey);
        collectible::mint_unregulated_nft_data(
            name,
            description,
            url,
            attribute_keys,
            attribute_values,
            U64_MAX,
            authority,
            ctx,
        );
    }

    // store the combination data in its own object, because it's easier than trying to store IDs as strings.
    // combinations use the combined obhject's id as the key.
    // Makes it easy to fetch the data, and there should only be one combination per element
    // In theory it'd be better to use a hash of from1 and from2, if you wanted an element to have more than 1 recipe
    public entry fun mint_combination(
        baseData: &mut BaseData,
        from1: ID,
        from2: ID,
        to: ID,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == baseData.admin, EUnauthorized);
        ofield::add(&mut baseData.id, to, Combination {id: object::new(ctx), from1, from2, to});
    }

    // make an element a basic, so users can mint them all in one transaction, and without having to combine anything to get them.
    public entry fun add_to_basics(
        baseData: &mut BaseData,
        c: &mut Collectible,
        ctx: &mut TxContext,
    ){
        assert!(tx_context::sender(ctx) == baseData.admin, EUnauthorized);
        let (contains, _) = vector::index_of<ID>(&baseData.elements, &object::id(c));
        assert!(!contains, EBasicExists);
        vector::push_back(&mut baseData.elements, object::id(c));
    }

    // just in case you want to remove a basic
    public entry fun remove_from_basics(
        baseData: &mut BaseData,
        c: ID,
        ctx: &mut TxContext,
    ){
        assert!(tx_context::sender(ctx) == baseData.admin, EUnauthorized);
        let (contains, index) = vector::index_of<ID>(&baseData.elements, &c);
        assert!(contains, EBasicNotFound);
        vector::remove(&mut baseData.elements, index);
    }

    // combines 2 elements into a new one. Checks if the combination elements match the submitted values
    public entry fun combine(
        baseData: &mut BaseData,
        a: &Nft<ELEMENTS, Collectible>,
        b: &Nft<ELEMENTS, Collectible>,
        c: &mut Collectible,
        ctx: &mut TxContext,
    ){
        let combination = ofield::borrow_mut<ID, Combination>(&mut baseData.id, object::id(c));
        
        assert!(
            (
                combination.from1 == nft::data_id(a) &&
                combination.from2 == nft::data_id(b)
            ) ||
            (
                combination.from1 == nft::data_id(b) &&
                combination.from2 == nft::data_id(a)
            ) &&
            combination.to == collectible::id(c),
        EWrongCombination);

        let authority = ofield::borrow_mut<u64, MintAuthority<ELEMENTS>>(&mut baseData.id, AuthorityKey);
        collectible::mint_nft<ELEMENTS, Collectible>(authority, c, tx_context::sender(ctx), ctx);
    }

    // prevents the need for a user to have 2 of the same element
    public entry fun combine_with_itself(
        baseData: &mut BaseData,
        a: &Nft<ELEMENTS, Collectible>,
        c: &mut Collectible,
        ctx: &mut TxContext,
    ){
        let combination = ofield::borrow_mut<ID, Combination>(&mut baseData.id, object::id(c));
        
        assert!(
            combination.from1 == nft::data_id(a) &&
            combination.from2 == nft::data_id(a) &&
            combination.to == collectible::id(c),
        EWrongCombination);
        let authority = ofield::borrow_mut<u64, MintAuthority<ELEMENTS>>(&mut baseData.id, AuthorityKey);
        collectible::mint_nft<ELEMENTS, Collectible>(authority, c, tx_context::sender(ctx), ctx);
    }

    // ideally the collectibles should be in an vector somehow. They're all shared objects though, so it's not easy to store the data like that
    public entry fun mint_starters(
        a: &mut Collectible,
        b: &mut Collectible,
        c: &mut Collectible,
        d: &mut Collectible,
        baseData: &mut BaseData,
        ctx: &mut TxContext,
    ) {
        let authority = ofield::borrow_mut<u64, MintAuthority<ELEMENTS>>(&mut baseData.id, AuthorityKey);
        if(vector::contains(&baseData.elements, &object::id(a))){
            collectible::mint_nft<ELEMENTS, Collectible>(authority, a, tx_context::sender(ctx), ctx);
        };
        if(vector::contains(&baseData.elements, &object::id(b))){
            collectible::mint_nft<ELEMENTS, Collectible>(authority, b, tx_context::sender(ctx), ctx);
        };
        if(vector::contains(&baseData.elements, &object::id(c))){
            collectible::mint_nft<ELEMENTS, Collectible>(authority, c, tx_context::sender(ctx), ctx);
        };
        if(vector::contains(&baseData.elements, &object::id(d))){
            collectible::mint_nft<ELEMENTS, Collectible>(authority, d, tx_context::sender(ctx), ctx);
        };
    }
}
