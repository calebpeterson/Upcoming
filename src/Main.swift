import Cocoa
import EventKit
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let eventStore = EKEventStore()
    var updateTimer: Timer?
    var notifiedEventIds = Set<String>()
    var introPopup: NSPanel?
    var currentPopupURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only app (no Dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menubar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Upcoming") {
                button.image = image
            }
            button.title = " Upcoming"
        }
        
        // Request calendar access and build menu
        requestCalendarAccess()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when popup windows close - we're a menubar app
        return false
    }
    
    func requestCalendarAccess() {
        eventStore.requestFullAccessToEvents { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("Calendar access granted")
                    self.refreshData()
                    self.startUpdateTimer()
                } else {
                    print("Calendar access denied: \(error?.localizedDescription ?? "unknown error")")
                    self.showAccessDeniedMenu()
                }
            }
        }
    }
    
    func startUpdateTimer() {
        // Re-query events and update every minute
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            print("Refreshing calendar data...")
            self?.refreshData()
        }
    }
    
    func refreshData() {
        // Fetch events once and use for both title and menu
        let allEvents = fetchTodayEvents()
        let regularEvents = filterRegularEvents(allEvents)
        
        // Title and notifications only use regular events
        updateStatusItemTitle(with: regularEvents)
        checkForUpcomingEventsAndNotify(events: regularEvents)
        
        // Menu shows all events
        updateMenu(with: allEvents)
    }
    
    func updateStatusItemTitle(with events: [EKEvent]) {
        guard let button = statusItem.button else { return }
        
        let nextEvent = findNextUpcomingEvent(from: events)
        
        if let event = nextEvent {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            let startTime = timeFormatter.string(from: event.startDate)
            let now = Date()
            
            var title = " \(startTime) - \(event.title ?? "Untitled")"
            
            // Check if event is in progress
            if now >= event.startDate && now < event.endDate {
                let remainingSeconds = event.endDate.timeIntervalSince(now)
                let remainingMinutes = Int(ceil(remainingSeconds / 60.0))
                title += " - \(remainingMinutes)m left"
            }
            // Check if event is upcoming within 60 minutes
            else if now < event.startDate {
                let timeUntilStart = event.startDate.timeIntervalSince(now)
                let minutesUntilStart = Int(ceil(timeUntilStart / 60.0))
                if minutesUntilStart <= 60 {
                    title += " - in \(minutesUntilStart) m"
                }
            }
            
            button.title = title
        } else {
            button.title = " No upcoming events"
        }
    }
    
    func findNextUpcomingEvent(from events: [EKEvent]) -> EKEvent? {
        let now = Date()
        
        // Find the first event that hasn't started yet or is currently happening
        return events.first { event in
            event.endDate > now
        }
    }
    
    func checkForUpcomingEventsAndNotify(events: [EKEvent]) {
        let now = Date()
        let twoMinutesFromNow = now.addingTimeInterval(2 * 60)
        
        for event in events {
            // Check if event is starting within 2 minutes and hasn't started yet
            if event.startDate > now && event.startDate <= twoMinutesFromNow {
                // Check if we've already notified about this event
                if !notifiedEventIds.contains(event.eventIdentifier) {
                    sendNotification(for: event)
                    notifiedEventIds.insert(event.eventIdentifier)
                }
            }
            
            // Clean up old notified event IDs for events that have already passed
            if event.endDate < now {
                notifiedEventIds.remove(event.eventIdentifier)
            }
        }
    }
    
    func sendNotification(for event: EKEvent) {
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let startTime = timeFormatter.string(from: event.startDate)
        
        let minutesUntilStart = Int(event.startDate.timeIntervalSinceNow / 60)
        let eventTitle = event.title ?? "Untitled"
        
        // Extract URL from event if available
        let eventURL = extractURL(from: event)
        
        // Show popup
        showPopup(
            title: "Upcoming Event",
            message: "\(eventTitle)\nStarts at \(startTime) (\(minutesUntilStart) minutes)",
            url: eventURL
        )
    }
    
    func showPopup(title: String, message: String, url: URL? = nil) {
        guard let button = statusItem.button else { return }
        
        // Close any existing popup
        introPopup?.close()
        
        // Store URL for Join button
        currentPopupURL = url
        
        // Calculate position below the menubar item
        let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
        
        // Create popup window
        let popupWidth: CGFloat = 320
        let popupHeight: CGFloat = 110
        let popupOrigin = NSPoint(
            x: buttonFrame.midX - popupWidth / 2,
            y: buttonFrame.minY - popupHeight - 10
        )
        
        let popupRect = NSRect(x: popupOrigin.x, y: popupOrigin.y, width: popupWidth, height: popupHeight)
        
        let popup = NSPanel(
            contentRect: popupRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.level = .floating
        popup.hidesOnDeactivate = false
        popup.becomesKeyOnlyIfNeeded = true
        
        // Create content view
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: popupHeight))
        contentView.wantsLayer = true
        
        // Background with proper blur and vibrancy effect
        let visualEffect = NSVisualEffectView(frame: contentView.bounds)
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        contentView.addSubview(visualEffect)
        
        // Add subtle shadow
        contentView.layer?.shadowColor = NSColor.black.cgColor
        contentView.layer?.shadowOpacity = 0.15
        contentView.layer?.shadowOffset = NSSize(width: 0, height: -2)
        contentView.layer?.shadowRadius = 8
        
        // Title label
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 12, y: popupHeight - 28, width: popupWidth - 24, height: 16)
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        contentView.addSubview(titleLabel)
        
        // Message label
        let messageLabel = NSTextField(labelWithString: message.replacingOccurrences(of: "\n", with: " "))
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.frame = NSRect(x: 12, y: 32, width: popupWidth - 24, height: 28)
        messageLabel.isBezeled = false
        messageLabel.drawsBackground = false
        messageLabel.isEditable = false
        messageLabel.isSelectable = false
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.cell?.wraps = true
        messageLabel.cell?.isScrollable = false
        contentView.addSubview(messageLabel)
        
        // Add buttons - Join button if URL exists, otherwise just Dismiss
        if url != nil {
            // Dismiss button
            let dismissButton = NSButton(frame: NSRect(x: popupWidth - 167, y: 10, width: 75, height: 32))
            dismissButton.title = "Dismiss"
            dismissButton.bezelStyle = .rounded
            dismissButton.controlSize = .large
            dismissButton.font = .systemFont(ofSize: 13)
            dismissButton.target = self
            dismissButton.action = #selector(dismissPopup)
            contentView.addSubview(dismissButton)
            
            // Join button (primary)
            let joinButton = NSButton(frame: NSRect(x: popupWidth - 88, y: 10, width: 75, height: 32))
            joinButton.title = "Join"
            joinButton.bezelStyle = .rounded
            joinButton.controlSize = .large
            joinButton.font = .systemFont(ofSize: 13)
            joinButton.keyEquivalent = "\r"
            joinButton.bezelColor = .controlAccentColor
            joinButton.contentTintColor = .white
            joinButton.target = self
            joinButton.action = #selector(joinEvent)
            contentView.addSubview(joinButton)
        } else {
            // Just Dismiss button
            let dismissButton = NSButton(frame: NSRect(x: popupWidth - 88, y: 10, width: 75, height: 32))
            dismissButton.title = "Dismiss"
            dismissButton.bezelStyle = .rounded
            dismissButton.controlSize = .large
            dismissButton.font = .systemFont(ofSize: 13)
            dismissButton.target = self
            dismissButton.action = #selector(dismissPopup)
            contentView.addSubview(dismissButton)
        }
        
        popup.contentView = contentView
        
        // Store popup reference
        introPopup = popup
        
        // Show popup without activating
        popup.orderFrontRegardless()
    }
    
    func showIntroPopup() {
        showPopup(
            title: "Upcoming",
            message: "Welcome! Upcoming is now monitoring\nyour calendar events."
        )
    }
    
    @objc func dismissPopup() {
        introPopup?.close()
        introPopup = nil
        currentPopupURL = nil
    }
    
    @objc func joinEvent() {
        guard let url = currentPopupURL else { return }
        NSWorkspace.shared.open(url)
        dismissPopup()
    }
    
    func updateMenu(with events: [EKEvent]) {
        let menu = NSMenu()
        
        if events.isEmpty {
            let noEventsItem = NSMenuItem(title: "No events today", action: nil, keyEquivalent: "")
            noEventsItem.isEnabled = false
            menu.addItem(noEventsItem)
        } else {
            let allDayEvents = filterAllDayOrMultiDayEvents(events)
            let regularEvents = filterRegularEvents(events)
            
            // Add all-day/multi-day events first
            if !allDayEvents.isEmpty {
                for event in allDayEvents {
                    let title: String
                    if event.isAllDay {
                        title = "All Day - \(event.title ?? "Untitled")"
                    } else {
                        title = "Multi-Day - \(event.title ?? "Untitled")"
                    }
                    
                    let eventItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    
                    // Store event with optional URL
                    let url = extractURL(from: event)
                    eventItem.representedObject = ["event": event, "url": url as Any]
                    eventItem.action = #selector(showEventPopup(_:))
                    eventItem.target = self
                    eventItem.isEnabled = true
                    
                    menu.addItem(eventItem)
                }
                
                // Add separator between all-day and regular events
                if !regularEvents.isEmpty {
                    menu.addItem(NSMenuItem.separator())
                }
            }
            
            // Add regular events
            for event in regularEvents {
                let timeFormatter = DateFormatter()
                timeFormatter.timeStyle = .short
                
                let startTime = timeFormatter.string(from: event.startDate)
                let title = "\(startTime) - \(event.title ?? "Untitled")"
                
                let eventItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                
                // Store event with optional URL
                let url = extractURL(from: event)
                eventItem.representedObject = ["event": event, "url": url as Any]
                eventItem.action = #selector(showEventPopup(_:))
                eventItem.target = self
                eventItem.isEnabled = true
                
                menu.addItem(eventItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let refreshItem = NSMenuItem(
            title: "Refresh",
            action: #selector(manualRefresh(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        let loginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        
        statusItem.menu = menu
    }
    
    func extractURL(from event: EKEvent) -> URL? {
        var allURLs: [URL] = []
        
        // Collect event URL if present
        if let url = event.url {
            allURLs.append(url)
        }
        
        // Collect URLs from notes
        if let notes = event.notes {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let matches = detector?.matches(in: notes, options: [], range: NSRange(location: 0, length: notes.utf16.count))
            
            for match in matches ?? [] {
                if let range = Range(match.range, in: notes) {
                    let urlString = String(notes[range])
                    if let url = URL(string: urlString) {
                        allURLs.append(url)
                    }
                }
            }
        }
        
        // Prefer Zoom URLs
        if let zoomURL = allURLs.first(where: { $0.absoluteString.contains("zoom.us") }) {
            return zoomURL
        }
        
        // Otherwise return the first URL found
        return allURLs.first
    }
    
    @objc func openEventURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
    
    @objc func showEventPopup(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let event = dict["event"] as? EKEvent else { return }
        
        let url = dict["url"] as? URL
        
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let startTime = timeFormatter.string(from: event.startDate)
        let endTime = timeFormatter.string(from: event.endDate)
        let eventTitle = event.title ?? "Untitled"
        
        showPopup(
            title: eventTitle,
            message: "\(startTime) - \(endTime)",
            url: url
        )
    }
    
    @objc func manualRefresh(_ sender: NSMenuItem) {
        print("Manual refresh triggered")
        refreshData()
    }
    
    func isLoginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
    
    @objc func toggleLoginItem(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            
            do {
                if service.status == .enabled {
                    try service.unregister()
                    print("Login item disabled")
                } else {
                    try service.register()
                    print("Login item enabled")
                }
                // Refresh menu to update checkmark
                refreshData()
            } catch {
                print("Failed to toggle login item: \(error.localizedDescription)")
            }
        }
    }
    
    func showAccessDeniedMenu() {
        let menu = NSMenu()
        
        let deniedItem = NSMenuItem(title: "Calendar access denied", action: nil, keyEquivalent: "")
        deniedItem.isEnabled = false
        menu.addItem(deniedItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        
        statusItem.menu = menu
    }
    
    func fetchTodayEvents() -> [EKEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: nil
        )
        
        let events = eventStore.events(matching: predicate)
        
        return events.sorted { $0.startDate < $1.startDate }
    }
    
    func isAllDayOrMultiDayEvent(_ event: EKEvent) -> Bool {
        if event.isAllDay {
            return true
        }
        
        let eventDuration = event.endDate.timeIntervalSince(event.startDate)
        let oneDayInSeconds: TimeInterval = 24 * 60 * 60
        if eventDuration >= oneDayInSeconds {
            return true
        }
        
        return false
    }
    
    func filterRegularEvents(_ events: [EKEvent]) -> [EKEvent] {
        return events.filter { !isAllDayOrMultiDayEvent($0) }
    }
    
    func filterAllDayOrMultiDayEvents(_ events: [EKEvent]) -> [EKEvent] {
        return events.filter { isAllDayOrMultiDayEvent($0) }
    }

}

// Manual "main"
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
