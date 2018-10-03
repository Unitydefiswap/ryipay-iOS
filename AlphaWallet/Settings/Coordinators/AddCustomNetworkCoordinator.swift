// Copyright SIX DAY LLC. All rights reserved.

import Foundation
import UIKit

protocol AddCustomNetworkCoordinatorDelegate: class {
    func didAddNetwork(network: CustomRPC, in coordinator: AddCustomNetworkCoordinator)
    func didCancel(in coordinator: AddCustomNetworkCoordinator)
}

class AddCustomNetworkCoordinator: Coordinator {
    private let navigationController: UINavigationController

    private lazy var addNetworkItem: UIBarButtonItem = {
        return UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addNetwork)
        )
    }()

    private lazy var addCustomNetworkController: AddCustomNetworkViewController = {
        let controller = AddCustomNetworkViewController()
        controller.navigationItem.rightBarButtonItem = addNetworkItem
        return controller
    }()

    var coordinators: [Coordinator] = []
    weak var delegate: AddCustomNetworkCoordinatorDelegate?

    init(
        navigationController: UINavigationController = NavigationController()
    ) {
        self.navigationController = navigationController
        self.navigationController.modalPresentationStyle = .formSheet
    }

    func start() {
        navigationController.viewControllers = [addCustomNetworkController]
    }

    @objc func addNetwork() {
        addCustomNetworkController.addNetwork { [weak self] result in
            guard let strongSelf = self else { return }
            switch result {
            case .success(let network):
                strongSelf.delegate?.didAddNetwork(network: network, in: strongSelf)
            case .failure: break
            }
        }
    }
}
