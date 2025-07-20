import UIKit

class ProjectListViewController: UITableViewController {
    
    private var projects: [ScanningProject] = []
    private let projectManager = ProjectManager.shared
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Scanning Projects"
        setupNavigationBar()
        setupTableView()
        loadProjects()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh projects in case room counts changed
        loadProjects()
    }
    
    private func setupNavigationBar() {
        let addButton = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(createNewProject)
        )
        navigationItem.rightBarButtonItem = addButton
        
        // Set large title
        navigationController?.navigationBar.prefersLargeTitles = true
    }
    
    private func setupTableView() {
        // Register a subtitle cell for better layout
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectCell")
        
        // Add some styling
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    }
    
    private func loadProjects() {
        // Run one-time migration of existing bundle data
        projectManager.migrateExistingBundleDataIfNeeded()
        
        projects = projectManager.loadProjects().sorted { 
            $0.lastModifiedDate > $1.lastModifiedDate
        }
        tableView.reloadData()
    }
    
    @objc private func createNewProject() {
        let alert = UIAlertController(
            title: "New Scanning Project",
            message: "Enter a name for your new project:",
            preferredStyle: .alert
        )
        
        alert.addTextField { textField in
            textField.placeholder = "e.g., My House, Office Building, Store Layout"
            textField.autocapitalizationType = .words
        }
        
        let createAction = UIAlertAction(title: "Create", style: .default) { _ in
            guard let textField = alert.textFields?.first,
                  let projectName = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !projectName.isEmpty else { return }
            
            let newProject = self.projectManager.createProject(name: projectName)
            self.projects.insert(newProject, at: 0) // Add to beginning
            
            let indexPath = IndexPath(row: 0, section: 0)
            self.tableView.insertRows(at: [indexPath], with: .automatic)
            
            // Navigate to the new project immediately
            self.openProject(newProject)
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alert.addAction(createAction)
        alert.addAction(cancelAction)
        
        present(alert, animated: true)
    }
    
    private func openProject(_ project: ScanningProject) {
        let roomTableVC = RoomTableViewController()
        roomTableVC.configure(with: project)
        navigationController?.pushViewController(roomTableVC, animated: true)
    }
    
    // MARK: - Table View Data Source
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if projects.isEmpty {
            return 1 // Show empty state cell
        }
        return projects.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "ProjectCell")
        
        if projects.isEmpty {
            cell.textLabel?.text = "No projects yet"
            cell.detailTextLabel?.text = "Tap + to create your first scanning project"
            cell.textLabel?.textColor = .systemGray
            cell.detailTextLabel?.textColor = .systemGray2
            cell.selectionStyle = .none
            cell.accessoryType = .none
        } else {
            let project = projects[indexPath.row]
            cell.textLabel?.text = project.name
            
            // Create detail text with room count and date
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .none
            
            let roomCountText = project.roomCount == 1 ? "1 room" : "\(project.roomCount) rooms"
            let dateText = dateFormatter.string(from: project.lastModifiedDate)
            cell.detailTextLabel?.text = "\(roomCountText) • Modified \(dateText)"
            
            cell.textLabel?.textColor = .label
            cell.detailTextLabel?.textColor = .systemGray
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
        }
        
        // Use subtitle style for better layout
        cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        
        return cell
    }
    
    // MARK: - Table View Delegate
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        guard !projects.isEmpty else { return }
        
        let project = projects[indexPath.row]
        openProject(project)
    }
    
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 60 // A bit taller for better appearance
    }
    
    // MARK: - Swipe Actions
    
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !projects.isEmpty else { return nil }
        
        let project = projects[indexPath.row]
        
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { _, _, completionHandler in
            self.confirmDeleteProject(project, at: indexPath)
            completionHandler(true)
        }
        deleteAction.image = UIImage(systemName: "trash")
        
        let renameAction = UIContextualAction(style: .normal, title: "Rename") { _, _, completionHandler in
            self.renameProject(project, at: indexPath)
            completionHandler(true)
        }
        renameAction.image = UIImage(systemName: "pencil")
        renameAction.backgroundColor = .systemBlue
        
        return UISwipeActionsConfiguration(actions: [deleteAction, renameAction])
    }
    
    private func confirmDeleteProject(_ project: ScanningProject, at indexPath: IndexPath) {
        let alert = UIAlertController(
            title: "Delete Project",
            message: "Are you sure you want to delete '\(project.name)'? This will permanently delete all \(project.roomCount) rooms and cannot be undone.",
            preferredStyle: .alert
        )
        
        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { _ in
            self.projectManager.deleteProject(project)
            self.projects.remove(at: indexPath.row)
            self.tableView.deleteRows(at: [indexPath], with: .fade)
            
            // If no projects left, reload to show empty state
            if self.projects.isEmpty {
                self.tableView.reloadData()
            }
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alert.addAction(deleteAction)
        alert.addAction(cancelAction)
        
        present(alert, animated: true)
    }
    
    private func renameProject(_ project: ScanningProject, at indexPath: IndexPath) {
        let alert = UIAlertController(
            title: "Rename Project",
            message: "Enter a new name for '\(project.name)':",
            preferredStyle: .alert
        )
        
        alert.addTextField { textField in
            textField.text = project.name
            textField.selectAll(nil)
            textField.autocapitalizationType = .words
        }
        
        let renameAction = UIAlertAction(title: "Rename", style: .default) { _ in
            guard let textField = alert.textFields?.first,
                  let newName = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !newName.isEmpty else { return }
            
            var updatedProject = project
            updatedProject.name = newName
            updatedProject.updateLastModified()
            
            self.projectManager.updateProject(updatedProject)
            self.projects[indexPath.row] = updatedProject
            
            // Re-sort and reload
            self.projects.sort { $0.lastModifiedDate > $1.lastModifiedDate }
            self.tableView.reloadData()
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alert.addAction(renameAction)
        alert.addAction(cancelAction)
        
        present(alert, animated: true)
    }
} 