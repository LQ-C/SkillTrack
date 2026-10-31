# skilltrack

Final Year Project "SkillTrack"

File Structure

lib/
├── app/                             # Application-wide configuration
│   ├── router/                      # Navigation and route definitions
│   ├── views/                       # Shared application shells
│   └── widgets/                     # Application-wide reusable widgets
│
├── core/                            # Code shared between multiple features
│   ├── constants/                   # Shared constants and configuration values
│   ├── errors/                      # Common exceptions and error messages
│   └── utils/                       # Reusable helpers and formatters
│
└── features/                        # Code grouped by business feature
    ├── ai_task_generation/          # AI task generation and preview
    │   ├── models/                  # Generated-task data structures
    │   ├── repositories/            # Task-generation data access
    │   ├── services/                # AI Edge Function communication
    │   ├── viewmodels/              # Generation and preview state
    │   ├── views/                   # Task-generation screens
    │   └── widgets/                 # Generation UI components
    │
    ├── authentication/              # Login, registration and session management
    │   ├── models/                  # User session and authentication data
    │   ├── repositories/            # Authentication contracts and Supabase access
    │   ├── services/                # External authentication services
    │   ├── viewmodels/              # Login and registration state
    │   ├── views/                   # Login and registration screens
    │   └── widgets/                 # Authentication form components
    │
    ├── dashboard/                   # User dashboard and overview
    │   ├── models/                  # Dashboard summary data
    │   ├── repositories/            # Dashboard data-access operations
    │   ├── services/                # Dashboard aggregation services
    │   ├── viewmodels/              # Dashboard state and loading logic
    │   ├── views/                   # Main dashboard screens
    │   └── widgets/                 # Summary cards and dashboard sections
    │
    ├── kanban/                      # Boards, tasks and task management
    │   ├── models/                  # Task, tag, priority and activity data
    │   ├── repositories/            # Kanban database operations
    │   ├── services/                # Kanban-specific coordination services
    │   ├── utils/                   # Kanban helpers and semantic colors
    │   ├── viewmodels/              # Board and archived-task state
    │   ├── views/                   # Board and archive screens
    │   └── widgets/                 # Task cards, forms and task details
    │
    ├── learning_integration/        # Learning resources and recommendations
    │   ├── models/                  # Learning-resource data structures
    │   ├── repositories/            # Resource data-access operations
    │   ├── services/                # External learning-resource integrations
    │   ├── viewmodels/              # Resource and recommendation state
    │   ├── views/                   # Learning-resource screens
    │   └── widgets/                 # Resource cards and related components
    │
    ├── notifications/               # In-app, realtime and push notifications
    │   ├── models/                  # Notification and preference data
    │   ├── repositories/            # Notifications and device-token access
    │   ├── services/                # Realtime and push services
    │   ├── viewmodels/              # Notification list and preference state
    │   ├── views/                   # Notification screens
    │   └── widgets/                 # Notification tiles and filters
    │
    ├── profile/                     # User account and profile management
    │   ├── models/                  # Profile and account data
    │   ├── repositories/            # Profile data-access operations
    │   ├── services/                # Profile image and account services
    │   ├── viewmodels/              # Profile editing and account state
    │   ├── views/                   # Profile and account screens
    │   └── widgets/                 # Avatar and profile form components
    │
    ├── projects/                    # Project creation and management
    │   ├── models/                  # Project data structures
    │   ├── repositories/            # Project database operations
    │   ├── services/                # Project-specific coordination services
    │   ├── viewmodels/              # Project form and dashboard state
    │   ├── views/                   # Project dashboard and creation screens
    │   └── widgets/                 # Project cards and form components
    │
    └── task_monitoring/             # Task stagnation monitoring and analytics
        ├── models/                  # Monitoring and stagnation data
        ├── repositories/            # Monitoring data-access operations
        ├── services/                # Monitoring and scoring coordination
        ├── viewmodels/              # Monitoring dashboard state
        ├── views/                   # Monitoring and analytics screens
        └── widgets/                 # Stagnation indicators and monitoring cards
    
This follows a feature-based MVVM structure:
- models represent data.
- repositories access Supabase or other data sources.
- services communicate with external systems.
- viewmodels manage screen state and business flow.
- views are complete screens.
- widgets are smaller reusable UI components.
- core contains shared code that does not belong to one feature.
- app handles global navigation, theming and application structure.
