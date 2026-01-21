import ViewInspector
import SwiftUI
@testable import Retain

// MARK: - Main Views

extension ContentView: Inspectable {}
extension SidebarView: Inspectable {}
extension ConversationListView: Inspectable {}
extension ConversationDetailView: Inspectable {}

// MARK: - Onboarding Views

extension OnboardingView: Inspectable {}
extension WelcomeStepView: Inspectable {}
extension CLISourcesStepView: Inspectable {}
extension CLISourceCard: Inspectable {}
extension WebAccountsStepView: Inspectable {}
extension WebAccountCard: Inspectable {}
extension ReadyStepView: Inspectable {}
extension FeatureCard: Inspectable {}
extension SourceSummaryRow: Inspectable {}

// MARK: - Settings Views

extension SettingsView: Inspectable {}
extension GeneralSettingsView: Inspectable {}
extension DataSourcesSettingsView: Inspectable {}
extension DataSourceRow: Inspectable {}
extension WebAccountsSettingsView: Inspectable {}
extension WebAccountRowView: Inspectable {}
extension LearningsSettingsView: Inspectable {}
// extension AdvancedSettingsView: Inspectable {} // Removed - type no longer exists

// MARK: - Conversation Browser

extension ConversationHeader: Inspectable {}
extension ConversationListHeader: Inspectable {}
extension ConversationListRow: Inspectable {}
extension MessageBubble: Inspectable {}
extension MessageContentView: Inspectable {}
extension CodeBlockView: Inspectable {}

// MARK: - Components

extension ProviderBadge: Inspectable {}
extension ProviderIcon: Inspectable {}
extension ProviderSidebarRow: Inspectable {}
extension SyncOverlay: Inspectable {}
extension SyncStatusBar: Inspectable {}
extension SyncCompleteToast: Inspectable {}
extension SyncErrorBanner: Inspectable {}

// MARK: - Sidebar

extension SmartFolderRow: Inspectable {}
extension SidebarFooter: Inspectable {}

// MARK: - Empty States

extension EmptyStateView: Inspectable {}
extension EmptyConversationListView: Inspectable {}
extension EmptySearchResultsView: Inspectable {}

// MARK: - Analytics

extension AnalyticsView: Inspectable {}
extension StatCard: Inspectable {}
extension ContributionGridView: Inspectable {}
extension ContributionCell: Inspectable {}
extension ContributionLegendSwatch: Inspectable {}
extension DailyProviderStackView: Inspectable {}
extension ProviderList: Inspectable {}
extension ProjectRow: Inspectable {}
extension RecentConversationRow: Inspectable {}

// MARK: - Learning

extension LearningReviewView: Inspectable {}
extension QueueHeader: Inspectable {}
extension EmptyQueueView: Inspectable {}
extension LearningQueueRow: Inspectable {}
extension LearningDetailView: Inspectable {}
extension ConfidenceBadge: Inspectable {}
extension ExportLearningsSheet: Inspectable {}

// MARK: - Menu Bar

extension MenuBarView: Inspectable {}

// MARK: - Web Login

extension WebLoginSheet: Inspectable {}
