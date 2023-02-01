module nfts::alchemy {
    use std::string::{Self, String};
    use std::vector;

    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::dynamic_object_field as ofield;
    use sui::url;
    
    use nft_protocol::display;
    use nft_protocol::transfer_allowlist;
    use nft_protocol::collection::{Self, MintCap};
    use nft_protocol::flyweight::{Self, Archetype};
    use nft_protocol::nft::{Self, Nft};

    const U64_MAX: u64 = 18446744073709551615;
    const AuthorityKey: u64 = 0;
    const AllowlistKey: u64 = 1;
    /// The type identifier of the NFT. The NFTs will have a type
    /// tag of kind: `Coin<package_object::mycoin::MYCOIN>`
    ///Name must not match the module name, as one time witnesses cannot be stored.
    struct ELEMENTS has store, drop {}
    struct NFTCarrier has key { id: UID, nft: ELEMENTS }
    struct Witness has drop {}

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
        _royalty_receiver: address,
        _tags: vector<vector<u8>>,
        _royalty_fee_bps: u64,
        _json: vector<u8>,
        carrier: NFTCarrier,
        baseData: &mut BaseData,
        ctx: &mut TxContext,
    ) {
        let NFTCarrier { id, nft: witness } = carrier;
        object::delete(id);

        let (mint_cap, collection) = collection::create<ELEMENTS>(
            & witness,
            ctx,
        );
        let allowlist = transfer_allowlist::create<ELEMENTS>(ELEMENTS {}, ctx);
        let collectionControlCap = transfer_allowlist::create_collection_cap<ELEMENTS, Witness>(& Witness {}, ctx);
        transfer_allowlist::insert_collection<ELEMENTS, ELEMENTS>(ELEMENTS {}, & collectionControlCap, &mut allowlist);
        transfer::transfer(collectionControlCap, tx_context::sender(ctx));
        
        display::add_collection_display_domain<ELEMENTS>(
            &mut collection,
            &mut mint_cap,
            string::utf8(b"Keepsake Alchemy"),
            string::utf8(b"A NFT collection of elements")
        );

        display::add_collection_symbol_domain(
            &mut collection,
            &mut mint_cap,
            string::utf8(b"KSAL")
        );
        
        // ofield::add(&mut baseData.id, AllowlistKey, allowlist);
        transfer::share_object(allowlist);
        ofield::add(&mut baseData.id, AuthorityKey, mint_cap);

        // let royalty = royalty::new(ctx);
        // royalty::add_proportional_royalty(
        //     &mut royalty,
        //     nft_protocol::royalty_strategy_bps::new(royalty_fee_bps),
        // );
        // royalty::add_royalty_domain(&mut collection, &mut mint_cap, royalty);

        transfer::share_object(collection);
    }

    fun mint(
        name: String,
        description: String,
        url: vector<u8>,
        attribute_keys: vector<String>,
        attribute_values: vector<String>,
        ctx: &mut TxContext,
    ) : Nft<ELEMENTS> {
        let minted = nft::new<ELEMENTS, Witness>(& Witness {}, tx_context::sender(ctx), ctx);
        
        display::add_display_domain<ELEMENTS>(&mut minted, name, description, ctx);
        display::add_url_domain(&mut minted, url::new_unsafe_from_bytes(url), ctx);
        display::add_attributes_domain_from_vec<ELEMENTS>(&mut minted, attribute_keys, attribute_values, ctx);
        minted
    }

    // creates collectible data for an element (think of it as a blueprint or a mould)
    public entry fun mint_data(
        name: String,
        description: String,
        url: vector<u8>,
        attribute_keys: vector<String>,
        attribute_values: vector<String>,
        baseData: &mut BaseData,
        ctx: &mut TxContext,
    ){
        assert!(tx_context::sender(ctx) == baseData.admin, EUnauthorized);
        let mint_cap = ofield::borrow_mut<u64, MintCap<ELEMENTS>>(&mut baseData.id, AuthorityKey);
        // let allowlist = ofield::borrow_mut<u64, Allowlist>(&mut baseData.id, AuthorityKey);
        let archetype = flyweight::new<ELEMENTS>(& ELEMENTS {}, U64_MAX, mint_cap, ctx);
        // let nft = flyweight::borrow_nft_mut(&mut archetype, mint_cap); // mint(name, description, url, attribute_keys, attribute_values, ctx);
        
        /*
        display::add_display_domain<ELEMENTS>(nft, name, description, ctx);
        display::add_url_domain(nft, url::new_unsafe_from_bytes(url), ctx);
        display::add_attributes_domain_from_vec<ELEMENTS>(nft, attribute_keys, attribute_values, ctx);
        */
        transfer::share_object(archetype);
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
        c: &mut Archetype<ELEMENTS>,
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

    public fun verify_combination(
        baseData: &mut BaseData,
        a: & ID,
        b: & ID,
        c: ID
    ) : bool {
        let combination = ofield::borrow_mut<ID, Combination>(&mut baseData.id, c);
            ((
                & combination.from1 == a &&
                & combination.from2 == b
            ) ||
            (
                & combination.from1 == b &&
                & combination.from2 == a
            ) &&
            combination.to == c)
    }

    // combines 2 elements into a new one. Checks if the combination elements match the submitted values
    public entry fun combine(
        baseData: &mut BaseData,
        a: &Nft<ELEMENTS>,
        b: &Nft<ELEMENTS>,
        c: &mut Archetype<ELEMENTS>,
        ctx: &mut TxContext,
    ){
        let archetype_a = nft::borrow_domain<ELEMENTS, ID>(a);
        let archetype_b = nft::borrow_domain<ELEMENTS, ID>(b);
        
        assert!(verify_combination(baseData, archetype_a, archetype_b,  object::id(c)), EWrongCombination);

        let mint_cap = ofield::borrow_mut<u64, MintCap<ELEMENTS>>(&mut baseData.id, AuthorityKey);
        mint_nft(mint_cap, c, tx_context::sender(ctx), ctx);
    }

    // prevents the need for a user to have 2 of the same element
    public entry fun combine_with_itself(
        baseData: &mut BaseData,
        a: &Nft<ELEMENTS>,
        c: &mut Archetype<ELEMENTS>,
        ctx: &mut TxContext,
    ){
        let archetype = nft::borrow_domain<ELEMENTS, ID>(a);

        assert!(verify_combination(baseData, archetype, archetype, object::id(c)), EWrongCombination);

        let mint_cap = ofield::borrow_mut<u64, MintCap<ELEMENTS>>(&mut baseData.id, AuthorityKey);
        mint_nft(mint_cap, c, tx_context::sender(ctx), ctx);
    }

    fun mint_nft(mint_cap: &mut MintCap<ELEMENTS>, archetype: &mut Archetype<ELEMENTS>, recipient: address, ctx: &mut TxContext) {
        let minted = nft::new<ELEMENTS, Witness>(& Witness {},recipient, ctx);
        flyweight::set_archetype(ctx, &mut minted, archetype, mint_cap);
        nft::add_domain<ELEMENTS, ID>(&mut minted, object::id(archetype), ctx);
        transfer::transfer(minted, recipient);
    }

    // ideally the collectibles should be in an vector somehow. They're all shared objects though, so it's not easy to store the data like that
    public entry fun mint_starters(
        a: &mut Archetype<ELEMENTS>,
        b: &mut Archetype<ELEMENTS>,
        c: &mut Archetype<ELEMENTS>,
        d: &mut Archetype<ELEMENTS>,
        baseData: &mut BaseData,
        ctx: &mut TxContext,
    ) {
        let recipient = tx_context::sender(ctx);
        let mint_cap = ofield::borrow_mut<u64, MintCap<ELEMENTS>>(&mut baseData.id, AuthorityKey);
        if(vector::contains(&baseData.elements, &object::id(a))){
            mint_nft(mint_cap, a, recipient, ctx);
        };
        if(vector::contains(&baseData.elements, &object::id(b))){
            mint_nft(mint_cap, b, recipient, ctx);
        };
        if(vector::contains(&baseData.elements, &object::id(c))){
            mint_nft(mint_cap, c, recipient, ctx);
        };
        if(vector::contains(&baseData.elements, &object::id(d))){
            mint_nft(mint_cap, d, recipient, ctx);
        };
    }
}
