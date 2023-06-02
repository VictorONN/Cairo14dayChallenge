#[contract]

mod Multisig {

    use array::ArrayTrait;
    use starknet::get_caller_address();

    struct Storage {
        numConfirmationsRequired: usize,
        isOwner: LegacyMap<ContractAddress, bool>,
        isConfirmed: LegacyMap<ContractAddress, bool>,
        // owners: Array<ContractAddress>,
        //mapping from tx index => owner => bool
        approved: LegacyMap<uint, LegacyMap<address, bool>>,
    }


    ////////////////////EVENTS

    #[event]
    fn Deposit(sender: ContractAddress, amount: usize, balance: usize) {}

    #[event]
    fn SubmitTransaction (
        owner: ContractAddress, 
        txIndex: usize, 
        to: ContractAddress, 
        value: usize,
        data: Array<felt252>) {}

    #[event]
    fn ConfirmTransaction(owner: ContractAddress, txId: usize) {}

    #[event]
    fn RevokeTransaction(owner: ContractAddress, txId: usize) {}

    #[event]
    fn ExecuteTransaction(owner: ContractAddress, txId: usize) {}


    struct Transaction {
        to: ContractAddress,
        value: usize,
        data: Array<felt252>,
        executed: bool,
    }




    #[constructor]
    fn constructor(_numConfirmationsRequired: _usize, _owners: Array<ContractAddress> ){
        // ensure we have more than 1 owner
        assert(_owners.len() > 0, 'Owners required');
        
        assert(_numConfirmationsRequired > 0, 'invalid number of required confirmations');

        assert (_numConfirmationsRequired <= _owners.len(), 'invalid number of required confirmations');
        
        // TODO: Loop through owners to ensure no duplicates, zero addresses(are they in Cairo?) etc

        let mut multisig_owners: Array<252> = _owners;
        loop {

            if multisig_owners(i) 

            isOwner::write(contractAddress, true);


            

        }


    }

    // TODO: propose a transaction
    #[external]
    fn submit_transaction(to: ContractAddress, value: usize, data: Array<felt252>) {

        let caller = get_caller_address();
        assert(is_Owner(caller), 'not an owner!');


        SubmitTransaction(caller, tx_id);
        return();
    }
    

    // TODO: An owner should confirm the transaction
    #[external]
    fn confirm_transaction(tx_index: usize)  {
        let caller = get_caller_address();
        assert(is_Owner(caller), 'not an owner!');


        ConfirmTransaction(caller, tx_index)
        return();
    }

    #[external]
    fn execute_transaction(txId: usize) {
        let caller = get_caller_address();
        assert(is_Owner(caller), 'not an owner!');

        //read no of confirmations for transaction
        assert()

        // turn transaction executed to true 

        // make the function call 


        ExecuteTransaction(caller, txId);
        return();        
    }

    #[external]
    fn revoke_confirmation(txId: usize) -> felt252 {
        let caller = get_caller_address();
        assert(is_Owner(caller), 'not an owner!');

        //confirm transaction is confirmed

        //reduce the confirmations by 1 and also turn confirmation to false


        RevokeTransaction(caller, txId);
        return(); 


        
    }


}