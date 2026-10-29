import UIKit

final class ListController: UITableViewController {
    let sections = [["closed c", "half typed", "to a"], ["+ New Document", "a", "b", "untitled 1"]]
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Documents"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
    }
    override func numberOfSections(in t: UITableView) -> Int { 2 }
    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].count }
    override func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let c = t.dequeueReusableCell(withIdentifier: "c", for: i)
        let text = sections[i.section][i.row]
        c.textLabel?.text = text
        c.textLabel?.textColor = text.hasPrefix("+") ? .systemBlue : .label
        let x = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
        x.tintColor = .systemBlue
        c.accessoryView = x
        return c
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let a = UIAlertController(title: "unsaved changes", message: "b has unsaved changes", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Discard", style: .default))
            a.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
            self.navigationController!.present(a, animated: false)
            print("ALERTPROBE: presented over the sheet")
        }
    }
}

final class Root: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.backgroundColor = .systemBackground
        let nav = UINavigationController(rootViewController: ListController(style: .insetGrouped))
        if let sheet = nav.sheetPresentationController { sheet.detents = [.large()] }
        present(nav, animated: false)
    }
}

final class Delegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window!.rootViewController = Root()
        window!.makeKeyAndVisible()
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Delegate.self))
