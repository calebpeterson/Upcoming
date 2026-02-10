import Cocoa
import EventKit
import ServiceManagement

private final class RoundedBackgroundView: NSView {
    var cornerRadius: CGFloat = 10

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let eventStore = EKEventStore()
    var updateTimer: Timer?
    var notifiedEventIds = Set<String>()
    var introPopup: NSPanel?
    var currentPopupURL: URL?
    var currentPopupStartDate: Date?
    var currentPopupEvent: EKEvent?
    var dismissButton: NSButton?
    var autoJoinButton: NSButton?
    var copyButton: NSButton?
    var autoJoinCountdownTimer: Timer?

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
    
    func formatTimeRemaining(minutes: Int) -> String {
        if minutes > 90 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d", hours, mins)
        } else {
            return "\(minutes)m"
        }
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
                let formattedTime = formatTimeRemaining(minutes: remainingMinutes)
                title += " - \(formattedTime) left"
            }
            // Check if event is upcoming within 60 minutes
            else if now < event.startDate {
                let timeUntilStart = event.startDate.timeIntervalSince(now)
                let minutesUntilStart = Int(ceil(timeUntilStart / 60.0))
                if minutesUntilStart <= 60 {
                    let formattedTime = formatTimeRemaining(minutes: minutesUntilStart)
                    title += " - in \(formattedTime)"
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
            url: eventURL,
            startDate: event.startDate,
            event: event
        )
    }
    
    func showPopup(title: String, message: String, url: URL? = nil, startDate: Date? = nil, event: EKEvent? = nil) {
        guard let button = statusItem.button else { return }
        
        // Close any existing popup
        introPopup?.close()
        
        // Store URL, start date, and event for buttons
        currentPopupURL = url
        currentPopupStartDate = startDate
        currentPopupEvent = event
        
        // Calculate position below the menubar item
        let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
        
        // Create popup window with initial size (will be adjusted after layout)
        let popupWidth: CGFloat = 320
        let initialHeight: CGFloat = 110
        let popupOrigin = NSPoint(
            x: buttonFrame.midX - popupWidth / 2,
            y: buttonFrame.minY - initialHeight - 10
        )
        
        let popupRect = NSRect(x: popupOrigin.x, y: popupOrigin.y, width: popupWidth, height: initialHeight)
        
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
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: initialHeight))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 10
        contentView.layer?.masksToBounds = true

        let backgroundView = RoundedBackgroundView(frame: contentView.bounds)
        backgroundView.cornerRadius = 10
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backgroundView, positioned: .below, relativeTo: nil)

        // Title label - allow wrapping
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.wraps = true
        titleLabel.cell?.isScrollable = false
        titleLabel.preferredMaxLayoutWidth = popupWidth - 24
        titleLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        
        // Message label - allow flexible height and wrapping
        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isBezeled = false
        messageLabel.drawsBackground = false
        messageLabel.isEditable = false
        messageLabel.isSelectable = false
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.cell?.wraps = true
        messageLabel.cell?.isScrollable = false
        messageLabel.preferredMaxLayoutWidth = popupWidth - 24
        messageLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(messageLabel)
        
        // Create button container for flexbox-like layout
        let buttonContainer = NSView()
        buttonContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonContainer)
        
        // Add buttons - Copy button (left), Dismiss and Auto-join (right)
        
        // Copy button (icon only) - only shown when we have an event
        if event != nil {
            let copyBtn = NSButton()
            copyBtn.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copy event details")
            copyBtn.isBordered = false
            copyBtn.imagePosition = .imageOnly
            copyBtn.toolTip = "Copy all details to clipboard"
            copyBtn.target = self
            copyBtn.action = #selector(copyEventToClipboard)
            copyBtn.translatesAutoresizingMaskIntoConstraints = false
            buttonContainer.addSubview(copyBtn)
            self.copyButton = copyBtn
        }
        
        let dismissBtn = NSButton()
        dismissBtn.title = "Dismiss"
        dismissBtn.bezelStyle = .rounded
        dismissBtn.controlSize = .large
        dismissBtn.font = .systemFont(ofSize: 13)
        dismissBtn.target = self
        dismissBtn.action = #selector(dismissPopup)
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false
        buttonContainer.addSubview(dismissBtn)
        self.dismissButton = dismissBtn
        
        if url != nil && startDate != nil {
            let button = NSButton()
            button.title = "Auto-join"
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.font = .systemFont(ofSize: 13)
            button.keyEquivalent = "\r"
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
            button.target = self
            button.action = #selector(scheduleAutoJoin)
            button.translatesAutoresizingMaskIntoConstraints = false
            buttonContainer.addSubview(button)
            self.autoJoinButton = button
        }
        
        // Set up Auto Layout constraints
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Title label - top padding, leading/trailing padding
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            
            // Message label - below title with spacing, flexible height
            messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            
            // Button container - at bottom with padding
            buttonContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            buttonContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            buttonContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            buttonContainer.heightAnchor.constraint(equalToConstant: 32),
            
            // Message label spacing above button container
            messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: buttonContainer.topAnchor, constant: -12),
        ])
        
        // Button constraints
        
        // Copy button constraints (lower-left)
        if let copyBtn = self.copyButton {
            NSLayoutConstraint.activate([
                copyBtn.leadingAnchor.constraint(equalTo: buttonContainer.leadingAnchor, constant: 12),
                copyBtn.topAnchor.constraint(equalTo: buttonContainer.topAnchor),
                copyBtn.bottomAnchor.constraint(equalTo: buttonContainer.bottomAnchor),
                copyBtn.widthAnchor.constraint(equalToConstant: 32),
            ])
        }
        
        if let autoJoinBtn = self.autoJoinButton {
            NSLayoutConstraint.activate([
                // Auto-join button - trailing edge (wide enough for countdown text)
                autoJoinBtn.trailingAnchor.constraint(equalTo: buttonContainer.trailingAnchor, constant: -12),
                autoJoinBtn.topAnchor.constraint(equalTo: buttonContainer.topAnchor),
                autoJoinBtn.bottomAnchor.constraint(equalTo: buttonContainer.bottomAnchor),
                autoJoinBtn.widthAnchor.constraint(equalToConstant: 160),
                
                // Dismiss button - before auto-join button
                dismissBtn.trailingAnchor.constraint(equalTo: autoJoinBtn.leadingAnchor, constant: -8),
                dismissBtn.topAnchor.constraint(equalTo: buttonContainer.topAnchor),
                dismissBtn.bottomAnchor.constraint(equalTo: buttonContainer.bottomAnchor),
                dismissBtn.widthAnchor.constraint(equalToConstant: 75),
            ])
        } else {
            NSLayoutConstraint.activate([
                // Dismiss button - trailing edge
                dismissBtn.trailingAnchor.constraint(equalTo: buttonContainer.trailingAnchor, constant: -12),
                dismissBtn.topAnchor.constraint(equalTo: buttonContainer.topAnchor),
                dismissBtn.bottomAnchor.constraint(equalTo: buttonContainer.bottomAnchor),
                dismissBtn.widthAnchor.constraint(equalToConstant: 75),
            ])
        }
        
        popup.contentView = contentView
        
        // Set up width constraint for proper height calculation
        contentView.widthAnchor.constraint(equalToConstant: popupWidth).isActive = true
        
        // Force layout to calculate actual size
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        
        // Calculate actual height needed using Auto Layout fitting size
        let fittingSize = contentView.fittingSize
        let actualHeight = max(fittingSize.height, initialHeight)
        
        // Update popup size and position
        let updatedOrigin = NSPoint(
            x: buttonFrame.midX - popupWidth / 2,
            y: buttonFrame.minY - actualHeight - 10
        )
        popup.setFrame(NSRect(x: updatedOrigin.x, y: updatedOrigin.y, width: popupWidth, height: actualHeight), display: true)
        
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
        autoJoinCountdownTimer?.invalidate()
        autoJoinCountdownTimer = nil
        introPopup?.close()
        introPopup = nil
        currentPopupURL = nil
        currentPopupStartDate = nil
        currentPopupEvent = nil
        dismissButton = nil
        autoJoinButton = nil
        copyButton = nil
    }
    
    @objc func copyEventToClipboard() {
        guard let event = currentPopupEvent else { return }
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        
        var eventDict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "startDate": dateFormatter.string(from: event.startDate),
            "endDate": dateFormatter.string(from: event.endDate),
            "isAllDay": event.isAllDay,
        ]
        
        // Status
        let statusString: String
        switch event.status {
        case .none: statusString = "none"
        case .confirmed: statusString = "confirmed"
        case .tentative: statusString = "tentative"
        case .canceled: statusString = "canceled"
        @unknown default: statusString = "unknown"
        }
        eventDict["status"] = statusString
        
        // Availability
        let availabilityString: String
        switch event.availability {
        case .notSupported: availabilityString = "notSupported"
        case .busy: availabilityString = "busy"
        case .free: availabilityString = "free"
        case .tentative: availabilityString = "tentative"
        case .unavailable: availabilityString = "unavailable"
        @unknown default: availabilityString = "unknown"
        }
        eventDict["availability"] = availabilityString
        
        if let location = event.location, !location.isEmpty {
            eventDict["location"] = location
        }
        
        // Structured location with coordinates
        if let structuredLocation = event.structuredLocation {
            var locDict: [String: Any] = [:]
            if let title = structuredLocation.title, !title.isEmpty {
                locDict["title"] = title
            }
            if let geoLocation = structuredLocation.geoLocation {
                locDict["latitude"] = geoLocation.coordinate.latitude
                locDict["longitude"] = geoLocation.coordinate.longitude
            }
            if structuredLocation.radius > 0 {
                locDict["radius"] = structuredLocation.radius
            }
            if !locDict.isEmpty {
                eventDict["structuredLocation"] = locDict
            }
        }
        
        if let notes = event.notes, !notes.isEmpty {
            eventDict["notes"] = notes
        }
        
        if let url = event.url {
            eventDict["url"] = url.absoluteString
        }
        
        if let timeZone = event.timeZone {
            eventDict["timeZone"] = timeZone.identifier
        }
        
        if let calendar = event.calendar {
            var calDict: [String: Any] = [
                "title": calendar.title,
            ]
            let calTypeString: String
            switch calendar.type {
            case .local: calTypeString = "local"
            case .calDAV: calTypeString = "calDAV"
            case .exchange: calTypeString = "exchange"
            case .subscription: calTypeString = "subscription"
            case .birthday: calTypeString = "birthday"
            @unknown default: calTypeString = "unknown"
            }
            calDict["type"] = calTypeString
            eventDict["calendar"] = calDict
        }
        
        if let organizer = event.organizer {
            var orgDict: [String: Any] = [:]
            if let name = organizer.name {
                orgDict["name"] = name
            }
            orgDict["email"] = organizer.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            orgDict["isCurrentUser"] = organizer.isCurrentUser
            eventDict["organizer"] = orgDict
        }
        
        if let attendees = event.attendees, !attendees.isEmpty {
            eventDict["attendees"] = attendees.map { attendee in
                var attendeeDict: [String: Any] = [
                    "email": attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                    "isCurrentUser": attendee.isCurrentUser,
                ]
                if let name = attendee.name {
                    attendeeDict["name"] = name
                }
                let statusStr: String
                switch attendee.participantStatus {
                case .unknown: statusStr = "unknown"
                case .pending: statusStr = "pending"
                case .accepted: statusStr = "accepted"
                case .declined: statusStr = "declined"
                case .tentative: statusStr = "tentative"
                case .delegated: statusStr = "delegated"
                case .completed: statusStr = "completed"
                case .inProcess: statusStr = "inProcess"
                @unknown default: statusStr = "unknown"
                }
                attendeeDict["status"] = statusStr
                let roleStr: String
                switch attendee.participantRole {
                case .unknown: roleStr = "unknown"
                case .required: roleStr = "required"
                case .optional: roleStr = "optional"
                case .chair: roleStr = "chair"
                case .nonParticipant: roleStr = "nonParticipant"
                @unknown default: roleStr = "unknown"
                }
                attendeeDict["role"] = roleStr
                let typeStr: String
                switch attendee.participantType {
                case .unknown: typeStr = "unknown"
                case .person: typeStr = "person"
                case .room: typeStr = "room"
                case .resource: typeStr = "resource"
                case .group: typeStr = "group"
                @unknown default: typeStr = "unknown"
                }
                attendeeDict["type"] = typeStr
                return attendeeDict
            }
        }
        
        if event.hasRecurrenceRules, let rules = event.recurrenceRules, !rules.isEmpty {
            eventDict["recurrenceRules"] = rules.map { rule in
                var ruleDict: [String: Any] = [:]
                let freqStr: String
                switch rule.frequency {
                case .daily: freqStr = "daily"
                case .weekly: freqStr = "weekly"
                case .monthly: freqStr = "monthly"
                case .yearly: freqStr = "yearly"
                @unknown default: freqStr = "unknown"
                }
                ruleDict["frequency"] = freqStr
                ruleDict["interval"] = rule.interval
                if let end = rule.recurrenceEnd {
                    if let endDate = end.endDate {
                        ruleDict["endDate"] = dateFormatter.string(from: endDate)
                    } else if end.occurrenceCount > 0 {
                        ruleDict["occurrenceCount"] = end.occurrenceCount
                    }
                }
                return ruleDict
            }
        }
        
        if event.hasAlarms, let alarms = event.alarms, !alarms.isEmpty {
            eventDict["alarms"] = alarms.map { alarm in
                var alarmDict: [String: Any] = [:]
                alarmDict["relativeOffset"] = alarm.relativeOffset
                if let absoluteDate = alarm.absoluteDate {
                    alarmDict["absoluteDate"] = dateFormatter.string(from: absoluteDate)
                }
                return alarmDict
            }
        }
        
        if let creationDate = event.creationDate {
            eventDict["creationDate"] = dateFormatter.string(from: creationDate)
        }
        
        if let lastModifiedDate = event.lastModifiedDate {
            eventDict["lastModifiedDate"] = dateFormatter.string(from: lastModifiedDate)
        }
        
        eventDict["occurrenceDate"] = dateFormatter.string(from: event.occurrenceDate)
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: eventDict, options: [.prettyPrinted, .sortedKeys])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(jsonString, forType: .string)
                
                // Show "Copied" tooltip temporarily
                if let btn = copyButton {
                    btn.toolTip = "Copied"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.copyButton?.toolTip = "Copy all details to clipboard"
                    }
                }
            }
        } catch {
            print("Failed to serialize event to JSON: \(error)")
        }
    }
    
    @objc func scheduleAutoJoin() {
        guard let url = currentPopupURL,
              let startDate = currentPopupStartDate,
              let autoJoinBtn = autoJoinButton,
              let dismissBtn = dismissButton else { return }
        
        // Cancel any existing countdown timer
        autoJoinCountdownTimer?.invalidate()
        
        let now = Date()
        let delay = startDate.timeIntervalSince(now)
        
        if delay <= 0 {
            // Meeting has already started, join immediately
            performJoin(url: url)
            dismissPopup()
            return
        }
        
        // Disable auto-join button and remove Enter key equivalent
        autoJoinBtn.isEnabled = false
        autoJoinBtn.keyEquivalent = ""
        
        // Change Dismiss to Cancel
        dismissBtn.title = "Cancel"
        dismissBtn.action = #selector(cancelAutoJoin)
        
        // Update button with initial countdown
        updateAutoJoinCountdown()
        
        // Start countdown timer that fires every second
        autoJoinCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateAutoJoinCountdown()
        }
    }
    
    @objc func cancelAutoJoin() {
        // Stop the countdown
        autoJoinCountdownTimer?.invalidate()
        autoJoinCountdownTimer = nil
        
        // Reset buttons to initial state
        if let autoJoinBtn = autoJoinButton {
            autoJoinBtn.title = "Auto-join"
            autoJoinBtn.isEnabled = true
            autoJoinBtn.keyEquivalent = "\r"
        }
        
        if let dismissBtn = dismissButton {
            dismissBtn.title = "Dismiss"
            dismissBtn.action = #selector(dismissPopup)
        }
    }
    
    func updateAutoJoinCountdown() {
        guard let url = currentPopupURL,
              let startDate = currentPopupStartDate,
              let button = autoJoinButton else { return }
        
        let now = Date()
        let remaining = startDate.timeIntervalSince(now)
        
        if remaining <= 0 {
            // Time to join
            autoJoinCountdownTimer?.invalidate()
            autoJoinCountdownTimer = nil
            performJoin(url: url)
            dismissPopup()
            return
        }
        
        // Format as M:SS
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        button.title = String(format: "Auto-joining in %d:%02d", minutes, seconds)
    }
    
    func performJoin(url: URL) {
        let passcodeToCopy: String? = currentPopupEvent.flatMap { event in
            event.notes.flatMap { extractPasscode(from: $0) }
        }
        if let passcode = passcodeToCopy {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(passcode, forType: .string)
        }
        let urlToOpen = convertToZoomAppURL(url) ?? url
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSWorkspace.shared.open(urlToOpen)
        }
    }
    
    func convertToZoomAppURL(_ url: URL) -> URL? {
        let urlString = url.absoluteString
        
        // Check if it's a Zoom URL
        guard urlString.contains("zoom.us") || urlString.contains("zoom.com") else {
            return nil
        }
        
        // Extract meeting ID from various Zoom URL formats
        // Examples:
        // https://zoom.us/j/123456789
        // https://us02web.zoom.us/j/123456789
        // https://zoom.us/j/123456789?pwd=password
        // https://zoom.us/s/123456789
        
        let pattern = #"zoom\.(?:us|com)/[js]/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        
        let range = NSRange(location: 0, length: urlString.utf16.count)
        guard let match = regex.firstMatch(in: urlString, options: [], range: range),
              let meetingIDRange = Range(match.range(at: 1), in: urlString) else {
            return nil
        }
        
        let meetingID = String(urlString[meetingIDRange])
        
        // Convert to zoom:// URL scheme to open Zoom app directly
        if let zoomAppURL = URL(string: "zoommtg://zoom.us/join?confno=\(meetingID)") {
            return zoomAppURL
        }
        
        return nil
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
    
    func extractPasscode(from notes: String) -> String? {
        let pattern = #"passcode:\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(location: 0, length: notes.utf16.count)
        guard let match = regex.firstMatch(in: notes, options: [], range: range),
              let captureRange = Range(match.range(at: 1), in: notes) else { return nil }
        return String(notes[captureRange])
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
        
        // Collect URLs from location
        if let location = event.location {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let matches = detector?.matches(in: location, options: [], range: NSRange(location: 0, length: location.utf16.count))
            
            for match in matches ?? [] {
                if let range = Range(match.range, in: location) {
                    let urlString = String(location[range])
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
            url: url,
            startDate: event.startDate,
            event: event
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
