/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A simplified view controller for scanning and merging rooms.
*/

import UIKit
import RoomPlan

// Simple structure to store scanned room data
struct ScannedRoom {
    let name: String
    let capturedRoom: CapturedRoom
}

class RoomTableViewController: UITableViewController {

    /// An array of scanned rooms
    private var scannedRooms: [ScannedRoom] = []
    
    /// An object that builds a single structure by merging multiple rooms
    private let structureBuilder = StructureBuilder(options: [.beautifyObjects])
    
    /// An object that holds a merged result
    private var finalResults: CapturedStructure?
    
    /// Room capture session for continuous scanning
    private var roomCaptureSession: RoomCaptureSession?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Room Scanner"
        setupNavigationBar()
        
        // Initialize room capture session for continuous scanning
        roomCaptureSession = RoomCaptureSession()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
        updateMergeButton()
    }
    
    private func setupNavigationBar() {
        let scanButton = UIBarButtonItem(title: "Scan New Room", style: .plain, target: self, action: #selector(scanNewRoom))
        navigationItem.rightBarButtonItem = scanButton
        
        let mergeButton = UIBarButtonItem(title: "Merge & Export", style: .plain, target: self, action: #selector(mergeAndExport))
        mergeButton.isEnabled = false
        navigationItem.leftBarButtonItem = mergeButton
    }
    
    private func updateMergeButton() {
        navigationItem.leftBarButtonItem?.isEnabled = scannedRooms.count >= 2
    }

    // MARK: - Table view data source

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if scannedRooms.isEmpty {
            return 1 // Show instruction cell
        }
        return scannedRooms.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RoomCell", for: indexPath)
        
        if scannedRooms.isEmpty {
            cell.textLabel?.text = "Tap 'Scan New Room' to get started"
            cell.textLabel?.textColor = .systemGray
            cell.selectionStyle = .none
        } else {
            cell.textLabel?.text = scannedRooms[indexPath.row].name
            cell.textLabel?.textColor = .label
            cell.selectionStyle = .default
        }
        
        return cell
    }

    // MARK: - Scanning functionality

    @objc private func scanNewRoom() {
        presentRoomCapture()
    }
    
    private func presentRoomCapture() {
        let scanViewController = RoomScanViewController()
        scanViewController.delegate = self
        scanViewController.sharedRoomCaptureSession = roomCaptureSession
        
        let navController = UINavigationController(rootViewController: scanViewController)
        navController.modalPresentationStyle = .fullScreen
        present(navController, animated: true)
    }
    
    // MARK: - Room capture completion
    
    func roomScanCompleted(capturedRoom: CapturedRoom) {
        promptForRoomName(capturedRoom: capturedRoom)
    }
    
    private func promptForRoomName(capturedRoom: CapturedRoom) {
        let alert = UIAlertController(title: "Name Your Room", message: "Enter a name for the scanned room:", preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "e.g., Bedroom, Kitchen, Living Room"
        }
        
        let saveAction = UIAlertAction(title: "Save", style: .default) { _ in
            guard let textField = alert.textFields?.first,
                  let roomName = textField.text,
                  !roomName.isEmpty else { return }
            
            let scannedRoom = ScannedRoom(name: roomName, capturedRoom: capturedRoom)
            self.scannedRooms.append(scannedRoom)
            self.tableView.reloadData()
            self.updateMergeButton()
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alert.addAction(saveAction)
        alert.addAction(cancelAction)
        
        present(alert, animated: true)
    }

    // MARK: - Merging functionality

    @objc private func mergeAndExport() {
        guard scannedRooms.count >= 2 else {
            showAlert(title: "Need More Rooms", message: "Please scan at least 2 rooms before merging.")
            return
        }
        
        let capturedRoomArray = scannedRooms.map { $0.capturedRoom }
        
        // Show loading indicator
        let loadingAlert = UIAlertController(title: "Merging Rooms", message: "Please wait while we merge your rooms...", preferredStyle: .alert)
        present(loadingAlert, animated: true)
        
        Task {
            do {
                finalResults = try await structureBuilder.capturedStructure(from: capturedRoomArray)
                
                // Dismiss loading alert
                loadingAlert.dismiss(animated: true) {
                    self.exportMergedStructure()
                }
                
            } catch {
                loadingAlert.dismiss(animated: true) {
                    self.showAlert(title: "Merging Error", message: error.localizedDescription)
                }
            }
        }
    }
    
    private func exportMergedStructure() {
        do {
            let exportFolderURL = try createTmpExportFolder()
            let meshDestinationURL = exportFolderURL.appending(path: "MergedRooms.usdz")
            
            try createExportData(meshDestinationURL: meshDestinationURL)
            
            let activityVC = UIActivityViewController(activityItems: [exportFolderURL], applicationActivities: nil)
            activityVC.modalPresentationStyle = .popover
            activityVC.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
            
            present(activityVC, animated: true)
            
        } catch {
            showAlert(title: "Export Error", message: error.localizedDescription)
        }
    }
    
    /// Exports the merged captured structure in JSON and USDZ formats to a URL.
    private func createExportData(meshDestinationURL: URL) throws {
        guard let finalResults else { return }
        
        let roomDestinationURL = meshDestinationURL.deletingPathExtension().appendingPathExtension("json")
        try exportJson(from: finalResults, to: roomDestinationURL)
        
        let metadataDestinationURL = meshDestinationURL.deletingPathExtension().appendingPathExtension("plist")
        try finalResults.export(to: meshDestinationURL,
                                metadataURL: metadataDestinationURL,
                                exportOptions: [.mesh])
    }
    
    /// Exports the given captured structure in JSON format to a URL.
    private func exportJson(from capturedStructure: CapturedStructure, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(capturedStructure)
        try data.write(to: url)
    }
    
    /// Provides a temporary location on disk to export a 3D model to.
    private func createTmpExportFolder(
        tmpFolderURL: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let exportFolderURL = tmpFolderURL.appending(path: "MultiscanMergedExport")
        if FileManager.default.fileExists(atPath: exportFolderURL.path()) {
            try FileManager.default.removeItem(at: exportFolderURL)
        }
        try FileManager.default.createDirectory(at: exportFolderURL,
                                                withIntermediateDirectories: true)
        return exportFolderURL
    }
}

// MARK: - Alert helper
extension RoomTableViewController {
    func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Room Scan View Controller
class RoomScanViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    
    weak var delegate: RoomTableViewController?
    var sharedRoomCaptureSession: RoomCaptureSession?
    
    private var roomCaptureView: RoomCaptureView!
    private var isScanning = false
    private var finalResults: CapturedRoom?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Scan Room"
        setupUI()
        setupRoomCapture()
    }
    
    private func setupUI() {
        view.backgroundColor = .black
        
        let doneButton = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(doneScanning))
        let cancelButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelScanning))
        
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = doneButton
    }
    
    private func setupRoomCapture() {
        // Create RoomCaptureView with custom session if available
        if let sharedSession = sharedRoomCaptureSession {
            roomCaptureView = RoomCaptureView(frame: view.bounds, arSession: sharedSession.arSession)
        } else {
            roomCaptureView = RoomCaptureView(frame: view.bounds)
        }
        
        roomCaptureView.delegate = self
        roomCaptureView.captureSession.delegate = self
        
        view.addSubview(roomCaptureView)
        
        // Auto-layout constraints
        roomCaptureView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            roomCaptureView.topAnchor.constraint(equalTo: view.topAnchor),
            roomCaptureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomCaptureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            roomCaptureView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isScanning {
            stopSession()
        }
    }
    
    private func startSession() {
        guard !isScanning else { return }
        
        isScanning = true
        
        // Use continuous ARSession for multi-room scanning (pauseARSession: false)
        roomCaptureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }
    
    private func stopSession() {
        guard isScanning else { return }
        
        isScanning = false
        // Don't pause ARSession to maintain continuity for next scan
        roomCaptureView.captureSession.stop(pauseARSession: false)
    }
    
    @objc private func doneScanning() {
        stopSession()
    }
    
    @objc private func cancelScanning() {
        if isScanning {
            stopSession()
        }
        dismiss(animated: true)
    }
    
    // MARK: - RoomCaptureViewDelegate
    
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        return true
    }
    
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.showAlert(title: "Scan Error", message: error.localizedDescription)
            }
            return
        }
        
        finalResults = processedResult
        
        // Dismiss the scanning view and pass the result back
        DispatchQueue.main.async {
            self.dismiss(animated: true) {
                self.delegate?.roomScanCompleted(capturedRoom: processedResult)
            }
        }
    }
    
    // MARK: - RoomCaptureSessionDelegate
    
    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        // Optional: Handle real-time updates during scanning
    }
    
    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        // Optional: Handle real-time updates during scanning
    }
    
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        // Optional: Handle scanning instructions
    }
    
    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        // Optional: Handle session start
    }
    
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        // Optional: Handle session end
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
