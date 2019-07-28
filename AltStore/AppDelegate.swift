//
//  AppDelegate.swift
//  AltStore
//
//  Created by Riley Testut on 5/9/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import UserNotifications
import AVFoundation

import AltSign
import Roxas

private extension CFNotificationName
{
    static let requestAppState = CFNotificationName("com.altstore.RequestAppState" as CFString)
    static let appIsRunning = CFNotificationName("com.altstore.AppState.Running" as CFString)
    
    static func requestAppState(for appID: String) -> CFNotificationName
    {
        let name = String(CFNotificationName.requestAppState.rawValue) + "." + appID
        return CFNotificationName(name as CFString)
    }
    
    static func appIsRunning(for appID: String) -> CFNotificationName
    {
        let name = String(CFNotificationName.appIsRunning.rawValue) + "." + appID
        return CFNotificationName(name as CFString)
    }
}

private let ReceivedApplicationState: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void =
{ (center, observer, name, object, userInfo) in
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate, let name = name else { return }
    appDelegate.receivedApplicationState(notification: name)
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    
    private var runningApplications: Set<String>?
    private var isLaunching = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        self.isLaunching = true
        
        self.setTintColor()
        
        ServerManager.shared.startDiscovering()
        
        DatabaseManager.shared.start { (error) in
            if let error = error
            {
                print("Failed to start DatabaseManager.", error)
            }
            else
            {
                print("Started DatabaseManager")
                
                DispatchQueue.main.async {
                    AppManager.shared.update()
                }
            }
        }
        
        if UserDefaults.standard.firstLaunch == nil
        {
            Keychain.shared.reset()
            UserDefaults.standard.firstLaunch = Date()
        }
        
        self.prepareForBackgroundFetch()
        
        DispatchQueue.main.async {
            self.isLaunching = false
        }
                
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication)
    {
        ServerManager.shared.stopDiscovering()
    }

    func applicationWillEnterForeground(_ application: UIApplication)
    {
        AppManager.shared.update()
        ServerManager.shared.startDiscovering()
    }
}

private extension AppDelegate
{
    func setTintColor()
    {
        self.window?.tintColor = .altGreen
    }
}

extension AppDelegate
{
    private func prepareForBackgroundFetch()
    {
        // "Fetch" every hour, but then refresh only those that need to be refreshed (so we don't drain the battery).
        UIApplication.shared.setMinimumBackgroundFetchInterval(1 * 60 * 60)
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { (success, error) in
        }
        
        #if DEBUG
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)
    {
        let tokenParts = deviceToken.map { data -> String in
            return String(format: "%02.2hhx", data)
        }
        
        let token = tokenParts.joined()
        print("Push Token:", token)
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        self.application(application, performFetchWithCompletionHandler: completionHandler)
    }
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        let isLaunching = self.isLaunching
        let refreshIdentifier = UUID().uuidString
        
        let installedApps = InstalledApp.fetchAppsForBackgroundRefresh(in: DatabaseManager.shared.viewContext)
        guard !installedApps.isEmpty else {
            ServerManager.shared.stopDiscovering()
            completionHandler(.noData)
            return
        }
        
        self.runningApplications = []
        
        let identifiers = installedApps.compactMap { $0.bundleIdentifier }
        print("Apps to refresh:", identifiers)
        
        DispatchQueue.global().async {
            let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
            
            for identifier in identifiers
            {
                let appIsRunningNotification = CFNotificationName.appIsRunning(for: identifier)
                CFNotificationCenterAddObserver(notificationCenter, nil, ReceivedApplicationState, appIsRunningNotification.rawValue, nil, .deliverImmediately)
                
                let requestAppStateNotification = CFNotificationName.requestAppState(for: identifier)
                CFNotificationCenterPostNotification(notificationCenter, requestAppStateNotification, nil, nil, true)
            }
        }
        
        BackgroundTaskManager.shared.performExtendedBackgroundTask { (taskResult, taskCompletionHandler) in
            
            func finish(_ result: Result<[String: Result<InstalledApp, Error>], Error>)
            {
                // If finish is actually called, that means an error occured during installation.
                
                ServerManager.shared.stopDiscovering()
                
                self.scheduleFinishedRefreshingNotification(for: result, identifier: refreshIdentifier, isLaunching: isLaunching, delay: 0)
                
                taskCompletionHandler()
                
                DispatchQueue.main.async {
                    guard UIApplication.shared.applicationState == .background else { return }
                    
                    // Exit so that if background fetch occurs again soon we're not suspended.
                    exit(0)
                }
            }
            
            if let error = taskResult.error
            {
                print("Error starting extended background task. Aborting.", error)
                completionHandler(.failed)
                finish(.failure(error))
                return
            }
            
            var fetchAppsResult: Result<[App], Error>?
            var serversResult: Result<Void, Error>?
            
            let dispatchGroup = DispatchGroup()
            dispatchGroup.enter()
            dispatchGroup.enter()
            
            AppManager.shared.fetchApps() { (result) in
                fetchAppsResult = result
                dispatchGroup.leave()
                
                do
                {
                    let apps = try result.get()
                    
                    guard let context = apps.first?.managedObjectContext else { return }
                    
                    let updatesFetchRequest = InstalledApp.updatesFetchRequest()
                    updatesFetchRequest.includesPendingChanges = true
                    
                    let previousUpdatesFetchRequest = InstalledApp.updatesFetchRequest()
                    previousUpdatesFetchRequest.includesPendingChanges = false
                    
                    let previousUpdates = try context.fetch(previousUpdatesFetchRequest)
                    
                    try context.save()
                    
                    let updates = try context.fetch(updatesFetchRequest)
                    
                    for update in updates
                    {
                        guard !previousUpdates.contains(where: { $0.bundleIdentifier == update.bundleIdentifier }) else { continue }
                        
                        guard let storeApp = update.storeApp else { continue }
                        
                        let content = UNMutableNotificationContent()
                        content.title = NSLocalizedString("New Update Available", comment: "")
                        content.body = String(format: NSLocalizedString("%@ %@ is now available for download.", comment: ""), update.name, storeApp.version)
                        
                        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                        UNUserNotificationCenter.current().add(request)
                    }
                    
                    DispatchQueue.main.async {
                        UIApplication.shared.applicationIconBadgeNumber = updates.count
                    }
                }
                catch
                {
                    print("Error fetching apps:", error)
                }
            }
            
            dispatchGroup.notify(queue: .main) {
                guard let fetchAppsResult = fetchAppsResult, let serversResult = serversResult else {
                    completionHandler(.failed)
                    return
                }
                
                // Call completionHandler early to improve chances of refreshing in the background again.
                switch (fetchAppsResult, serversResult)
                {
                case (.success, .success): completionHandler(.newData)
                case (.success, .failure(ConnectionError.serverNotFound)): completionHandler(.newData)
                case (.failure, _), (_, .failure): completionHandler(.failed)
                }
            }
            
            // Wait for three seconds to:
            // a) give us time to discover AltServers
            // b) give other processes a chance to respond to requestAppState notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if ServerManager.shared.discoveredServers.isEmpty
                {
                    serversResult = .failure(ConnectionError.serverNotFound)
                }
                else
                {
                    serversResult = .success(())
                }
                
                dispatchGroup.leave()
                
                let filteredApps = installedApps.filter { !(self.runningApplications?.contains($0.bundleIdentifier) ?? false) }
                print("Filtered Apps to Refresh:", filteredApps.map { $0.bundleIdentifier })
                
                let group = AppManager.shared.refresh(filteredApps, presentingViewController: nil)
                group.beginInstallationHandler = { (installedApp) in
                    guard installedApp.bundleIdentifier == App.altstoreAppID else { return }
                    
                    // We're starting to install AltStore, which means the app is about to quit.
                    // So, we schedule a "refresh successful" local notification to be displayed after a delay,
                    // but if the app is still running, we cancel the notification.
                    // Then, we schedule another notification and repeat the process.
                    
                    // Also since AltServer has already received the app, it can finish installing even if we're no longer running in background.

                    if let error = group.error
                    {
                        self.scheduleFinishedRefreshingNotification(for: .failure(error), identifier: refreshIdentifier, isLaunching: isLaunching)
                    }
                    else
                    {
                        var results = group.results
                        results[installedApp.bundleIdentifier] = .success(installedApp)

                        self.scheduleFinishedRefreshingNotification(for: .success(results), identifier: refreshIdentifier, isLaunching: isLaunching)
                    }
                }
                group.completionHandler = { (result) in
                    finish(result)
                }
            }
        }
    }
    
    func receivedApplicationState(notification: CFNotificationName)
    {
        let baseName = String(CFNotificationName.appIsRunning.rawValue)
        
        let appID = String(notification.rawValue).replacingOccurrences(of: baseName + ".", with: "")
        self.runningApplications?.insert(appID)
    }
    
    func scheduleFinishedRefreshingNotification(for result: Result<[String: Result<InstalledApp, Error>], Error>, identifier: String, isLaunching: Bool, delay: TimeInterval = 5)
    {
        self.cancelFinishedRefreshingNotification(identifier: identifier)
        
        let content = UNMutableNotificationContent()
        
        var shouldPresentAlert = true
        
        do
        {
            let results = try result.get()
            shouldPresentAlert = !results.isEmpty
            
            for (_, result) in results
            {
                guard case let .failure(error) = result else { continue }
                throw error
            }
            
            content.title = NSLocalizedString("Refreshed Apps", comment: "")
            content.body = NSLocalizedString("All apps have been refreshed.", comment: "")
        }
        catch let error as NSError where
            (error.domain == NSOSStatusErrorDomain || error.domain == AVFoundationErrorDomain) &&
                error.code == AVAudioSession.ErrorCode.cannotStartPlaying.rawValue &&
                !isLaunching
        {
            // We can only start background audio when the app is being launched,
            // and _not_ if it's already suspended in background.
            // Since we are currently suspended in background and not launching, we'll just ignore the error.

            shouldPresentAlert = false
        }
        catch ConnectionError.serverNotFound
        {
            shouldPresentAlert = false
        }
        catch
        {
            print("Failed to refresh apps in background.", error)
            
            content.title = NSLocalizedString("Failed to Refresh Apps", comment: "")
            content.body = error.localizedDescription
            
            shouldPresentAlert = true
        }
        
        if shouldPresentAlert
        {
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay + 1, repeats: false)
            
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
            
            if delay > 0
            {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    // If app is still running at this point, we schedule another notification with same identifier.
                    // This prevents the currently scheduled notification from displaying, and starts another countdown timer.
                    self.scheduleFinishedRefreshingNotification(for: result, identifier: identifier, isLaunching: isLaunching)
                }
            }
        }
    }
    
    func cancelFinishedRefreshingNotification(identifier: String)
    {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
