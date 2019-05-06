// Copyright © 2018 Stormbird PTE. LTD.

import Foundation
import UIKit
import Alamofire
import RealmSwift
import TrustKeystore
import PromiseKit

enum ContractData {
    case name(String)
    case symbol(String)
    case balance([String])
    case decimals(UInt8)
    case nonFungibleTokenComplete(name: String, symbol: String, balance: [String], tokenType: TokenType)
    case fungibleTokenComplete(name: String, symbol: String, decimals: UInt8)
    case delegateTokenComplete
    case failed(networkReachable: Bool?)
}

protocol SingleChainTokenCoordinatorDelegate: class, CanOpenURL {
    func tokensDidChange(inCoordinator coordinator: SingleChainTokenCoordinator)
    func didPress(for type: PaymentFlow, inCoordinator coordinator: SingleChainTokenCoordinator)
    func didTap(transaction: Transaction, inViewController viewController: UIViewController, in coordinator: SingleChainTokenCoordinator)
}

class SingleChainTokenCoordinator: Coordinator {
    private let keystore: Keystore
    private let storage: TokensDataStore
    private let cryptoPrice: Subscribable<Double>
    private let assetDefinitionStore: AssetDefinitionStore
    private let navigationController: UINavigationController
    private let autoDetectTransactedTokensQueue: OperationQueue
    private let autoDetectTokensQueue: OperationQueue
    private var isAutoDetectingTransactedTokens = false
    private var isAutoDetectingTokens = false

    let session: WalletSession
    weak var delegate: SingleChainTokenCoordinatorDelegate?
    var coordinators: [Coordinator] = []

    init(
            session: WalletSession,
            keystore: Keystore,
            tokensStorage: TokensDataStore,
            ethPrice: Subscribable<Double>,
            assetDefinitionStore: AssetDefinitionStore,
            navigationController: UINavigationController,
            withAutoDetectTransactedTokensQueue autoDetectTransactedTokensQueue: OperationQueue,
            withAutoDetectTokensQueue autoDetectTokensQueue: OperationQueue
    ) {
        self.session = session
        self.keystore = keystore
        self.storage = tokensStorage
        self.cryptoPrice = ethPrice
        self.assetDefinitionStore = assetDefinitionStore
        self.navigationController = navigationController
        self.autoDetectTransactedTokensQueue = autoDetectTransactedTokensQueue
        self.autoDetectTokensQueue = autoDetectTokensQueue
    }

    func start() {
        //Since this is called at launch, we don't want it to block launching
        DispatchQueue.global().async {
            DispatchQueue.main.async { [weak self] in
                self?.autoDetectTransactedTokens()
                self?.autoDetectPartnerTokens()
                self?.refreshUponAssetDefinitionChanges()
            }
        }
    }

    func isServer(_ server: RPCServer) -> Bool {
        return session.server == server
    }

    private func refreshUponAssetDefinitionChanges() {
        assetDefinitionStore.subscribe { [weak self] _ in
            self?.storage.fetchTokenNamesForNonFungibleTokensIfEmpty()
        }
    }

    ///Implementation: We refresh once only, after all the auto detected tokens' data have been pulled because each refresh pulls every tokens' (including those that already exist before the this auto detection) price as well as balance, placing heavy and redundant load on the device. After a timeout, we refresh once just in case it took too long, so user at least gets the chance to see some auto detected tokens
    private func autoDetectTransactedTokens() {
        //TODO we don't auto detect tokens if we are running tests. Maybe better to move this into app delegate's application(_:didFinishLaunchingWithOptions:)
        guard ProcessInfo.processInfo.environment["XCInjectBundleInto"] == nil else { return }
        guard !session.config.isAutoFetchingDisabled else { return }
        guard let address = keystore.recentlyUsedWallet?.address else { return }
        guard !isAutoDetectingTransactedTokens else { return }

        isAutoDetectingTransactedTokens = true
        let operation = AutoDetectTransactedTokensOperation(forSession: session, coordinator: self, wallet: address)
        autoDetectTransactedTokensQueue.addOperation(operation)
    }

    private func autoDetectTransactedTokensImpl(wallet: Address, erc20: Bool) -> Promise<Void> {
        return Promise<Void> { seal in
            GetContractInteractions().getContractList(address: wallet.eip55String, server: session.server, erc20: erc20) { [weak self] contracts in
                defer {
                    seal.fulfill(())
                }
                guard let strongSelf = self else { return }
                guard let currentAddress = strongSelf.keystore.recentlyUsedWallet?.address, currentAddress.eip55String.sameContract(as: wallet.eip55String) else { return }
                let detectedContracts = contracts.map { $0.lowercased() }
                let alreadyAddedContracts = strongSelf.storage.enabledObject.map { $0.address.eip55String.lowercased() }
                let deletedContracts = strongSelf.storage.deletedContracts.map { $0.contract.lowercased() }
                let hiddenContracts = strongSelf.storage.hiddenContracts.map { $0.contract.lowercased() }
                let delegateContracts = strongSelf.storage.delegateContracts.map { $0.contract.lowercased() }
                let contractsToAdd = detectedContracts - alreadyAddedContracts - deletedContracts - hiddenContracts - delegateContracts
                var contractsPulled = 0
                var hasRefreshedAfterAddingAllContracts = false

                if contractsToAdd.isEmpty { return }

                DispatchQueue.global().async { [weak self] in
                    guard let strongSelf = self else { return }
                    for eachContract in contractsToAdd {
                        strongSelf.addToken(for: eachContract) {
                            contractsPulled += 1
                            if contractsPulled == contractsToAdd.count {
                                hasRefreshedAfterAddingAllContracts = true
                                DispatchQueue.main.async {
                                    strongSelf.delegate?.tokensDidChange(inCoordinator: strongSelf)
                                }
                            }
                        }
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if !hasRefreshedAfterAddingAllContracts {
                            strongSelf.delegate?.tokensDidChange(inCoordinator: strongSelf)
                        }
                    }
                }
            }
        }
    }

    private func autoDetectPartnerTokens() {
        guard !session.config.isAutoFetchingDisabled else { return }
        switch session.server {
        case .main:
            autoDetectMainnetPartnerTokens()
        case .xDai:
            autoDetectXDaiPartnerTokens()
        case .kovan, .ropsten, .rinkeby, .poa, .sokol, .classic, .callisto, .goerli, .custom:
            break
        }
    }

    private func autoDetectMainnetPartnerTokens() {
        autoDetectTokens(withContracts: Constants.partnerContracts)
    }

    private func autoDetectXDaiPartnerTokens() {
        autoDetectTokens(withContracts: Constants.ethDenverXDaiPartnerContracts)
    }

    private func autoDetectTokens(withContracts contractsToDetect: [(name: String, contract: String)]) {
        guard let address = keystore.recentlyUsedWallet?.address else { return }
        guard !isAutoDetectingTokens else { return }

        isAutoDetectingTokens = true
        let operation = AutoDetectTokensOperation(forSession: session, coordinator: self, wallet: address, tokens: contractsToDetect)
        autoDetectTokensQueue.addOperation(operation)
    }

    private func autoDetectTokensImpl(withContracts contractsToDetect: [(name: String, contract: String)], completion: @escaping () -> ()) {
        guard let address = keystore.recentlyUsedWallet?.address else { return }
        let alreadyAddedContracts = storage.enabledObject.map { $0.address.eip55String.lowercased() }
        let deletedContracts = storage.deletedContracts.map { $0.contract.lowercased() }
        let hiddenContracts = storage.hiddenContracts.map { $0.contract.lowercased() }
        let contracts = contractsToDetect.map { $0.contract.lowercased() } - alreadyAddedContracts - deletedContracts - hiddenContracts
        var contractsProcessed = 0
        guard !contracts.isEmpty else {
            completion()
            return
        }
        for each in contracts {
            guard let contract = Address(string: each) else {
                contractsProcessed += 1
                if contractsProcessed == contracts.count {
                    completion()
                }
                continue
            }
            storage.getTokenType(for: each) { tokenType in
                switch tokenType {
                case .erc875:
                    //TODO long and very similar code below. Extract function
                    let balanceCoordinator = GetERC875BalanceCoordinator(forServer: self.session.server)
                    balanceCoordinator.getERC875TokenBalance(for: address, contract: contract) { [weak self] result in
                        guard let strongSelf = self else {
                            contractsProcessed += 1
                            if contractsProcessed == contracts.count {
                                completion()
                            }
                            return
                        }
                        switch result {
                        case .success(let balance):
                            if !balance.isEmpty {
                                strongSelf.addToken(for: contract.eip55String) {
                                    DispatchQueue.main.async {
                                        strongSelf.delegate?.tokensDidChange(inCoordinator: strongSelf)
                                    }
                                }
                            }
                        case .failure:
                            break
                        }
                        contractsProcessed += 1
                        if contractsProcessed == contracts.count {
                            completion()
                        }
                    }
                case .erc20:
                    let balanceCoordinator = GetBalanceCoordinator(forServer: self.session.server)
                    balanceCoordinator.getBalance(for: address, contract: contract) { [weak self] result in
                        guard let strongSelf = self else {
                            contractsProcessed += 1
                            if contractsProcessed == contracts.count {
                                completion()
                            }
                            return
                        }
                        switch result {
                        case .success(let balance):
                            if balance > 0 {
                                strongSelf.addToken(for: contract.eip55String) {
                                    DispatchQueue.main.async {
                                        strongSelf.delegate?.tokensDidChange(inCoordinator: strongSelf)
                                    }
                                }
                            }
                        case .failure:
                            break
                        }
                        contractsProcessed += 1
                        if contractsProcessed == contracts.count {
                            completion()
                        }
                    }
                case .erc721:
                    //TODO should auto-detect ERC721 too
                        break
                case .nativeCryptocurrency:
                    break
                }
            }

        }
    }

    private func addToken(for contract: String, completion: @escaping () -> Void) {
        fetchContractData(for: contract) { [weak self] data in
            guard let strongSelf = self else { return }
            switch data {
            case .name, .symbol, .balance, .decimals:
                break
            case .nonFungibleTokenComplete(let name, let symbol, let balance, let tokenType):
                if let address = Address(string: contract) {
                    let token = ERCToken(
                            contract: address,
                            server: strongSelf.session.server,
                            name: name,
                            symbol: symbol,
                            decimals: 0,
                            type: tokenType,
                            balance: balance
                    )
                    strongSelf.storage.addCustom(token: token)
                    completion()
                }
            case .fungibleTokenComplete(let name, let symbol, let decimals):
                if let address = Address(string: contract) {
                    let token = TokenObject(
                            contract: address.eip55String,
                            server: strongSelf.session.server,
                            name: name,
                            symbol: symbol,
                            decimals: Int(decimals),
                            value: "0",
                            type: .erc20
                    )
                    strongSelf.storage.add(tokens: [token])
                    completion()
                }
            case .delegateTokenComplete:
                strongSelf.storage.add(delegateContracts: [DelegateContract(contract: contract, server: strongSelf.session.server)])
                completion()
            case .failed(let networkReachable):
                if let networkReachable = networkReachable, networkReachable {
                    strongSelf.storage.add(deadContracts: [DeletedContract(contract: contract, server: strongSelf.session.server)])
                }
                completion()
            }
        }
    }

    //Adding a token may fail if we lose connectivity while fetching the contract details (e.g. name and balance). So we remove the contract from the hidden list (if it was there) so that the app has the chance to add it automatically upon auto detection at startup
    func addImportedToken(forContract contract: String) {
        delete(hiddenContract: contract)
        addToken(for: contract) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.delegate?.tokensDidChange(inCoordinator: strongSelf)
        }
    }

    private func delete(hiddenContract contract: String) {
        guard let hiddenContract = storage.hiddenContracts.first(where: { $0.contract.sameContract(as: contract) }) else { return }
        //TODO we need to make sure it's all uppercase?
        storage.delete(hiddenContracts: [hiddenContract])
    }

    /// Failure to obtain contract data may be due to no-connectivity. So we should check .failed(networkReachable: Bool)
    func fetchContractData(for address: String, completion: @escaping (ContractData) -> Void) {
        var completedName: String?
        var completedSymbol: String?
        var completedBalance: [String]?
        var completedDecimals: UInt8?
        var completedTokenType: TokenType?
        var failed = false

        func callCompletionFailed() {
            guard !failed else { return }
            failed = true
            //TODO maybe better to share an instance of the reachability manager
            completion(.failed(networkReachable: NetworkReachabilityManager()?.isReachable))
        }

        func callCompletionAsDelegateTokenOrNot() {
            assert(completedSymbol != nil && completedSymbol?.isEmpty == true)
            //Must check because we also get an empty symbol (and name) if there's no connectivity
            //TODO maybe better to share an instance of the reachability manager
            if let reachabilityManager = NetworkReachabilityManager(), reachabilityManager.isReachable {
                completion(.delegateTokenComplete)
            } else {
                callCompletionFailed()
            }
        }

        func callCompletionOnAllData() {
            if let completedName = completedName, let completedSymbol = completedSymbol, let completedBalance = completedBalance, let tokenType = completedTokenType {
                if completedSymbol.isEmpty {
                    callCompletionAsDelegateTokenOrNot()
                } else {
                    completion(.nonFungibleTokenComplete(name: completedName, symbol: completedSymbol, balance: completedBalance, tokenType: tokenType))
                }
            } else if let completedName = completedName, let completedSymbol = completedSymbol, let completedDecimals = completedDecimals {
                if completedSymbol.isEmpty {
                    callCompletionAsDelegateTokenOrNot()
                } else {
                    completion(.fungibleTokenComplete(name: completedName, symbol: completedSymbol, decimals: completedDecimals))
                }
            }
        }

        assetDefinitionStore.fetchXML(forContract: address)

        storage.getContractName(for: address) { result in
            switch result {
            case .success(let name):
                completedName = name
                completion(.name(name))
                callCompletionOnAllData()
            case .failure:
                callCompletionFailed()
            }
        }

        storage.getContractSymbol(for: address) { result in
            switch result {
            case .success(let symbol):
                completedSymbol = symbol
                completion(.symbol(symbol))
                callCompletionOnAllData()
            case .failure:
                callCompletionFailed()
            }
        }

        storage.getTokenType(for: address) { [weak self] tokenType in
            guard let strongSelf = self else { return }
            completedTokenType = tokenType
            switch tokenType {
            case .erc875:
                strongSelf.storage.getERC875Balance(for: address) { result in
                    switch result {
                    case .success(let balance):
                        completedBalance = balance
                        completion(.balance(balance))
                        callCompletionOnAllData()
                    case .failure:
                        callCompletionFailed()
                    }
                }
            case .erc721:
                strongSelf.storage.getERC721Balance(for: address) { result in
                    switch result {
                    case .success(let balance):
                        completedBalance = balance
                        completion(.balance(balance))
                        callCompletionOnAllData()
                    case .failure:
                        callCompletionFailed()
                    }
                }
            case .erc20:
                strongSelf.storage.getDecimals(for: address) { result in
                    switch result {
                    case .success(let decimal):
                        completedDecimals = decimal
                        completion(.decimals(decimal))
                        callCompletionOnAllData()
                    case .failure:
                        callCompletionFailed()
                    }
                }
            case .nativeCryptocurrency:
                break
            }
        }
    }

    func showTokenList(for type: PaymentFlow, token: TokenObject) {
        guard !token.nonZeroBalance.isEmpty else {
            navigationController.displayError(error: NoTokenError())
            return
        }

        let tokensCardCoordinator = TokensCardCoordinator(
                session: session,
                keystore: keystore,
                tokensStorage: storage,
                ethPrice: cryptoPrice,
                token: token,
                assetDefinitionStore: assetDefinitionStore
        )
        addCoordinator(tokensCardCoordinator)
        tokensCardCoordinator.delegate = self
        tokensCardCoordinator.start()
        switch (type, session.account.type) {
        case (.send, .real), (.request, _):
            makeCoordinatorReadOnlyIfNotSupportedByOpenSeaERC721(coordinator: tokensCardCoordinator, token: token)
            navigationController.present(tokensCardCoordinator.navigationController, animated: true, completion: nil)
        case (.send, .watch), (.request, _):
            tokensCardCoordinator.isReadOnly = true
            navigationController.present(tokensCardCoordinator.navigationController, animated: true, completion: nil)
        case (_, _):
            navigationController.displayError(error: InCoordinatorError.onlyWatchAccount)
        }
    }

    private func makeCoordinatorReadOnlyIfNotSupportedByOpenSeaERC721(coordinator: TokensCardCoordinator, token: TokenObject) {
        switch token.type {
        case .nativeCryptocurrency, .erc20, .erc875:
            break
        case .erc721:
            switch OpenSeaNonFungibleTokenHandling(token: token) {
            case .supportedByOpenSea:
                break
            case .notSupportedByOpenSea:
                coordinator.isReadOnly = true
            }
        }
    }

    private func createTransactionsStore() -> TransactionsStorage? {
        guard let wallet = keystore.recentlyUsedWallet else { return nil }
        let realm = self.realm(forAccount: wallet)
        return TransactionsStorage(realm: realm, server: session.server)
    }

    private func realm(forAccount account: Wallet) -> Realm {
        let migration = MigrationInitializer(account: account)
        migration.perform()
        return try! Realm(configuration: migration.config)
    }

    func show(fungibleToken token: TokenObject, transferType: TransferType) {
        guard let transactionsStore = createTransactionsStore() else { return }

        let viewController = TokenViewController(session: session, tokensDataStore: storage, transferType: transferType)
        viewController.delegate = self
        let viewModel = TokenViewControllerViewModel(transferType: transferType, session: session, tokensStore: storage, transactionsStore: transactionsStore)
        viewController.configure(viewModel: viewModel)
        viewController.navigationItem.leftBarButtonItem = UIBarButtonItem(title: R.string.localizable.cancel(), style: .plain, target: self, action: #selector(dismiss))
        navigationController.present(UINavigationController(rootViewController: viewController), animated: true, completion: nil)
    }

    @objc func dismiss() {
        navigationController.dismiss(animated: true, completion: nil)
    }

    func delete(token: TokenObject) {
        storage.add(hiddenContracts: [HiddenContract(contract: token.contract, server: session.server)])
        storage.delete(tokens: [token])
        delegate?.tokensDidChange(inCoordinator: self)
    }

    func add(token: ERCToken) {
        storage.addCustom(token: token)
        delegate?.tokensDidChange(inCoordinator: self)
    }

    class AutoDetectTransactedTokensOperation: Operation {
        private let session: WalletSession
        weak private var coordinator: SingleChainTokenCoordinator?
        private let wallet: Address
        override var isExecuting: Bool {
            return coordinator?.isAutoDetectingTransactedTokens ?? false
        }
        override var isFinished: Bool {
            return !isExecuting
        }
        override var isAsynchronous: Bool {
            return true
        }

        init(forSession session: WalletSession, coordinator: SingleChainTokenCoordinator, wallet: Address) {
            self.session = session
            self.coordinator = coordinator
            self.wallet = wallet
            super.init()
            self.queuePriority = session.server.networkRequestsQueuePriority
        }

        override func main() {
            guard let strongCoordinator = coordinator else { return }
            let fetchErc20Tokens = strongCoordinator.autoDetectTransactedTokensImpl(wallet: wallet, erc20: true)
            let fetchNonErc20Tokens = strongCoordinator.autoDetectTransactedTokensImpl(wallet: wallet, erc20: false)
            when(fulfilled: [fetchErc20Tokens, fetchNonErc20Tokens]).done { _ in
                self.willChangeValue(forKey: "isExecuting")
                self.willChangeValue(forKey: "isFinished")
                self.coordinator?.isAutoDetectingTransactedTokens = false
                self.didChangeValue(forKey: "isExecuting")
                self.didChangeValue(forKey: "isFinished")
            }
        }
    }

    class AutoDetectTokensOperation: Operation {
        private let session: WalletSession
        weak private var coordinator: SingleChainTokenCoordinator?
        private let wallet: Address
        private let tokens: [(name: String, contract: String)]
        override var isExecuting: Bool {
            return coordinator?.isAutoDetectingTokens ?? false
        }
        override var isFinished: Bool {
            return !isExecuting
        }
        override var isAsynchronous: Bool {
            return true
        }

        init(forSession session: WalletSession, coordinator: SingleChainTokenCoordinator, wallet: Address, tokens: [(name: String, contract: String)]) {
            self.session = session
            self.coordinator = coordinator
            self.wallet = wallet
            self.tokens = tokens
            super.init()
            self.queuePriority = session.server.networkRequestsQueuePriority
        }

        override func main() {
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.coordinator?.autoDetectTokensImpl(withContracts: strongSelf.tokens) { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.willChangeValue(forKey: "isExecuting")
                    strongSelf.willChangeValue(forKey: "isFinished")
                    strongSelf.coordinator?.isAutoDetectingTokens = false
                    strongSelf.didChangeValue(forKey: "isExecuting")
                    strongSelf.didChangeValue(forKey: "isFinished")
                }
            }
        }
    }
}

extension SingleChainTokenCoordinator: TokensCardCoordinatorDelegate {
    func didCancel(in coordinator: TokensCardCoordinator) {
        navigationController.dismiss(animated: true)
        removeCoordinator(coordinator)
    }
}

extension SingleChainTokenCoordinator: TokenViewControllerDelegate {
    func didTapSend(forTransferType transferType: TransferType, inViewController viewController: TokenViewController) {
        delegate?.didPress(for: .send(type: transferType), inCoordinator: self)
    }

    func didTapReceive(forTransferType transferType: TransferType, inViewController viewController: TokenViewController) {
        delegate?.didPress(for: .request, inCoordinator: self)
    }

    func didTap(transaction: Transaction, inViewController viewController: TokenViewController) {
        delegate?.didTap(transaction: transaction, inViewController: viewController, in: self)
    }
}

extension SingleChainTokenCoordinator: CanOpenURL {
    func didPressViewContractWebPage(forContract contract: String, server: RPCServer, in viewController: UIViewController) {
        delegate?.didPressViewContractWebPage(forContract: contract, server: server, in: viewController)
    }

    func didPressViewContractWebPage(_ url: URL, in viewController: UIViewController) {
        delegate?.didPressViewContractWebPage(url, in: viewController)
    }

    func didPressOpenWebPage(_ url: URL, in viewController: UIViewController) {
        delegate?.didPressOpenWebPage(url, in: viewController)
    }
}
