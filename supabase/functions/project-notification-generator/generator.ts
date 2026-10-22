export type Preferences = {
  stalled_task_enabled: boolean;
  deadline_reminder_enabled: boolean;
  recommendation_enabled: boolean;
};

export type ProjectCandidate = {
  project_id: string;
  user_id: string;
  project_name: string;
  end_date: string | null;
  project_status: string;
  profile_exists: boolean;
};

export type TaskCandidate = {
  task_id: string;
  board_id: string;
  project_id: string;
  user_id: string;
  task_title: string;
  task_status: string;
  task_archived: boolean;
  board_archived: boolean;
  project_status: string;
  profile_exists: boolean;
  task_created_at: string;
  deadline: string | null;
  last_activity_at: string | null;
};

export type StagnationUpdate = {
  became_stalled: boolean;
  currently_stalled: boolean;
  current_stalled_at: string | null;
};

export type NotificationInsert = {
  user_id: string;
  type: "STALLED_TASK" | "DEADLINE_REMINDER";
  context_type: "TASK" | "PROJECT";
  project_id: string;
  board_id: string | null;
  task_id: string | null;
  title: string;
  message: string;
  unique_key: string;
  action_data: Record<string, never>;
};

export type NotificationStore = {
  listProjects(
    offset: number,
    limit: number,
  ): Promise<ProjectCandidate[]>;

  listTasks(
    offset: number,
    limit: number,
  ): Promise<TaskCandidate[]>;

  getPreferences(
    userId: string,
  ): Promise<Preferences>;

  updateTaskStagnation(
    taskId: string,
    score: number,
    checkedAt: Date,
  ): Promise<StagnationUpdate>;

  insert(
    notification: NotificationInsert,
  ): Promise<boolean>;
};

export type GenerationSummary = {
  projectsChecked: number;
  tasksChecked: number;
  created: number;
  duplicates: number;
  missingProfiles: number;
  failed: number;
};

const dayMs = 24 * 60 * 60 * 1000;
const pageSize = 100;
const applicationTimeZone = "Asia/Kuala_Lumpur";
const emptyActionData = {} as Record<string, never>;

const datePartsFormatter = new Intl.DateTimeFormat(
  "en-CA",
  {
    timeZone: applicationTimeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  },
);

const deadlineTimeFormatter = new Intl.DateTimeFormat(
  "en-MY",
  {
    timeZone: applicationTimeZone,
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  },
);

function parseDate(value: string): Date {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    throw new Error("Invalid candidate date");
  }

  return date;
}

function dateInApplicationTimeZone(
  value: Date,
): number {
  const parts = datePartsFormatter.formatToParts(value);

  const year = Number(
    parts.find((part) => part.type === "year")?.value,
  );

  const month = Number(
    parts.find((part) => part.type === "month")?.value,
  );

  const day = Number(
    parts.find((part) => part.type === "day")?.value,
  );

  if (
    !Number.isInteger(year) ||
    !Number.isInteger(month) ||
    !Number.isInteger(day)
  ) {
    throw new Error(
      "Unable to determine local calendar date",
    );
  }

  return Date.UTC(year, month - 1, day);
}

function formatDeadlineTime(
  deadline: Date,
): string {
  return deadlineTimeFormatter
    .format(deadline)
    .replace(/\bam\b/i, "AM")
    .replace(/\bpm\b/i, "PM");
}

function deadlineWindow(
  deadline: Date,
  now: Date,
): {
  key: string;
  phrase: string;
} | null {
  const deadlineDay =
    dateInApplicationTimeZone(deadline);

  const currentDay =
    dateInApplicationTimeZone(now);

  const days = Math.round(
    (deadlineDay - currentDay) / dayMs,
  );

  if (days === 3) {
    return {
      key: "3-days",
      phrase: "in 3 days",
    };
  }

  if (days === 1) {
    return {
      key: "1-day",
      phrase: "tomorrow",
    };
  }

  if (days === 0) {
    return {
      key: "today",
      phrase: "today",
    };
  }

  return null;
}

/**
 * Calculates a score from 0 to 100.
 *
 * The permitted inactivity is based on half of the task's
 * allocated duration:
 *
 * 1-day task  -> 1 inactive day
 * 3-day task  -> 2 inactive days
 * 5-day task  -> 3 inactive days
 * 10-day task -> 5 inactive days
 * 14+ days    -> maximum 7 inactive days
 *
 * Tasks without a deadline use 7 inactive days.
 */
function calculateStagnationScore(input: {
  createdAt: Date;
  lastActivityAt: Date;
  deadline: Date | null;
  status: string;
  now: Date;
}): number {
  const inactiveMilliseconds = Math.max(
    0,
    input.now.getTime() -
      input.lastActivityAt.getTime(),
  );

  const inactiveDays =
    inactiveMilliseconds / dayMs;

  let allowedInactivityDays = 7;

  if (input.deadline != null) {
    const durationMilliseconds = Math.max(
      dayMs,
      input.deadline.getTime() -
        input.createdAt.getTime(),
    );

    const durationDays = Math.max(
      1,
      Math.ceil(durationMilliseconds / dayMs),
    );

    allowedInactivityDays = Math.min(
      7,
      Math.max(
        1,
        Math.ceil(durationDays * 0.5),
      ),
    );
  }

  const inactivityPoints = Math.min(
    70,
    Math.floor(
      (
        inactiveDays /
        allowedInactivityDays
      ) * 70,
    ),
  );

  const isOverdue =
    input.deadline != null &&
    input.deadline.getTime() <
      input.now.getTime();

  const isDueWithinOneDay =
    input.deadline != null &&
    !isOverdue &&
    input.deadline.getTime() -
          input.now.getTime() <=
      dayMs;

  const deadlinePoints = isOverdue
    ? 20
    : isDueWithinOneDay
    ? 10
    : 0;

  const statusPoints =
    input.status === "in_progress" &&
      inactiveDays >= 1
      ? 10
      : 0;

  return Math.min(
    100,
    Math.max(
      0,
      inactivityPoints +
        deadlinePoints +
        statusPoints,
    ),
  );
}

function logGenerationFailure(
  category: string,
  error: unknown,
): void {
  const message = error instanceof Error
    ? error.message
    : "Unknown error";

  console.error(`${category} failed: ${message}`);
}

export async function generateNotifications(
  store: NotificationStore,
  now = new Date(),
): Promise<GenerationSummary> {
  const summary: GenerationSummary = {
    projectsChecked: 0,
    tasksChecked: 0,
    created: 0,
    duplicates: 0,
    missingProfiles: 0,
    failed: 0,
  };

  const preferenceCache = new Map<
    string,
    Promise<Preferences>
  >();

  const preferences = (
    userId: string,
  ): Promise<Preferences> => {
    let value = preferenceCache.get(userId);

    if (!value) {
      value = store.getPreferences(userId);
      preferenceCache.set(userId, value);
    }

    return value;
  };

  const insert = async (
    notification: NotificationInsert,
  ): Promise<void> => {
    const wasInserted = await store.insert(
      notification,
    );

    if (wasInserted) {
      summary.created++;
    } else {
      summary.duplicates++;
    }
  };

  // =========================================================
  // PROJECT DEADLINE NOTIFICATIONS
  // =========================================================

  for (let offset = 0; ; offset += pageSize) {
    const projects = await store.listProjects(
      offset,
      pageSize,
    );

    for (const project of projects) {
      summary.projectsChecked++;

      if (!project.profile_exists) {
        summary.missingProfiles++;
        continue;
      }

      try {
        if (
          project.project_status !== "active" ||
          !project.end_date
        ) {
          continue;
        }

        const settings = await preferences(
          project.user_id,
        );

        if (!settings.deadline_reminder_enabled) {
          continue;
        }

        const deadline = parseDate(
          project.end_date,
        );

        const window = deadlineWindow(
          deadline,
          now,
        );

        if (!window) {
          continue;
        }

        await insert({
          user_id: project.user_id,
          type: "DEADLINE_REMINDER",
          context_type: "PROJECT",
          project_id: project.project_id,
          board_id: null,
          task_id: null,
          title: "Project deadline approaching",
          message:
            `“${project.project_name}” is due ` +
            `${window.phrase}.`,
          unique_key:
            `project-deadline:${project.project_id}:` +
            `${project.end_date}:${window.key}`,
          action_data: emptyActionData,
        });
      } catch (error) {
        summary.failed++;

        logGenerationFailure(
          "Project deadline notification",
          error,
        );
      }
    }

    if (projects.length < pageSize) {
      break;
    }
  }

  // =========================================================
  // TASK PROCESSING
  // =========================================================

  for (let offset = 0; ; offset += pageSize) {
    const tasks = await store.listTasks(
      offset,
      pageSize,
    );

    for (const task of tasks) {
      summary.tasksChecked++;

      if (!task.profile_exists) {
        summary.missingProfiles++;
        continue;
      }

      if (
        task.project_status !== "active" ||
        task.board_archived ||
        task.task_archived ||
        task.task_status === "completed"
      ) {
        continue;
      }

      let settings: Preferences;

      try {
        settings = await preferences(
          task.user_id,
        );
      } catch (error) {
        summary.failed++;

        logGenerationFailure(
          "Notification preference loading",
          error,
        );

        continue;
      }

      let parsedDeadline: Date | null = null;

      if (task.deadline) {
        try {
          parsedDeadline = parseDate(
            task.deadline,
          );
        } catch (error) {
          summary.failed++;

          logGenerationFailure(
            "Task deadline parsing",
            error,
          );
        }
      }

      // =====================================================
      // STAGNATION SCORE AND STALLED FLAG
      // =====================================================

      if (task.last_activity_at) {
        try {
          const createdAt = parseDate(
            task.task_created_at,
          );

          const lastActivityAt = parseDate(
            task.last_activity_at,
          );

          const stagnationScore =
            calculateStagnationScore({
              createdAt,
              lastActivityAt,
              deadline: parsedDeadline,
              status: task.task_status,
              now,
            });

          const stagnation =
            await store.updateTaskStagnation(
              task.task_id,
              stagnationScore,
              now,
            );

          /*
           * Retry the notification on later runs while the task
           * remains stalled. The unique key prevents duplicates.
           */
          if (
            stagnation.currently_stalled &&
            settings.stalled_task_enabled &&
            stagnation.current_stalled_at
          ) {
            await insert({
              user_id: task.user_id,
              type: "STALLED_TASK",
              context_type: "TASK",
              project_id: task.project_id,
              board_id: task.board_id,
              task_id: task.task_id,
              title: "Task may be stalled",
              message:
                `“${task.task_title}” has a ` +
                `stagnation score of ` +
                `${stagnationScore}/100.`,
              unique_key:
                `stalled:${task.task_id}:` +
                stagnation.current_stalled_at,
              action_data: emptyActionData,
            });
          }
        } catch (error) {
          summary.failed++;

          logGenerationFailure(
            "Task stagnation calculation",
            error,
          );
        }
      }

      // =====================================================
      // TASK DEADLINE NOTIFICATION
      // =====================================================

      if (
        settings.deadline_reminder_enabled &&
        parsedDeadline
      ) {
        try {
          const window = deadlineWindow(
            parsedDeadline,
            now,
          );

          if (window) {
            const deadlineTime =
              formatDeadlineTime(parsedDeadline);

            await insert({
              user_id: task.user_id,
              type: "DEADLINE_REMINDER",
              context_type: "TASK",
              project_id: task.project_id,
              board_id: task.board_id,
              task_id: task.task_id,
              title: "Task deadline approaching",
              message:
                `“${task.task_title}” is due ` +
                `${window.phrase} at ` +
                `${deadlineTime}.`,
              unique_key:
                `task-deadline:${task.task_id}:` +
                `${parsedDeadline.toISOString()}:` +
                window.key,
              action_data: emptyActionData,
            });
          }
        } catch (error) {
          summary.failed++;

          logGenerationFailure(
            "Task deadline notification",
            error,
          );
        }
      }
    }

    if (tasks.length < pageSize) {
      break;
    }
  }

  return summary;
}