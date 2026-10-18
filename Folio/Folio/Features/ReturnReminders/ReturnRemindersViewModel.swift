//
//  ReturnRemindersViewModel.swift
//  Folio
//
//  Created by Brandon Hua on 17/10/2026.
//

import Foundation
import Observation

/// Holds what the reminders screen should display and loads it from the use case.
@MainActor @Observable final class ReturnRemindersViewModel {

    /// Every state the screen can be in.
    enum ScreenState: Equatable {
        case loading
        case loaded([ReminderSummary])   // has reminders to show
        case empty                     // loaded fine, but there are no reminders
        case failed(String)              // something went wrong; holds the message to show
    }

    /// What the screen is showing right now. The view reads this; only the view model changes it.
    private(set) var state: ScreenState = .loading

    private let loadReminderSummaries: LoadReminderSummaries
    private let deleteReturnReminder: DeleteReturnReminder

    init(loadReminderSummaries: LoadReminderSummaries, deleteReturnReminder: DeleteReturnReminder) {
        self.loadReminderSummaries = loadReminderSummaries
        self.deleteReturnReminder = deleteReturnReminder
    }

    /// Fetches the reminder rows and updates what the screen shows.
    func load() async {
        // Show the spinner while we fetch
        state = .loading

        do {
            // Ask the use case for the rows
            let summaries = try await loadReminderSummaries()

            // Decide which state fits what came back
            if summaries.isEmpty {
                state = .empty
            } else {
                state = .loaded(summaries)
            }
        } catch {
            // Show a readable message instead of crashing
            state = .failed(error.localizedDescription)
        }
    }
    
    /// Deletes a reminder, then reloads the list so the screen matches what's saved.
    func delete(id: UUID) async {
        do {
            try await deleteReturnReminder(id: id)
            await load()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
