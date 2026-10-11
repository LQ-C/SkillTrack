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
  deadline: string | null;
  last_activity_at: string | null;
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
  listProjects(offset: number, limit: number): Promise<ProjectCandidate[]>;
  listTasks(offset: number, limit: number): Promise<TaskCandidate[]>;
  getPreferences(userId: string): Promise<Preferences>;
  /** True when inserted, false when the unique key already exists. */
  insert(notification: NotificationInsert): Promise<boolean>;
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
const stalledMs = 7 * dayMs;
const pageSize = 100;
const emptyActionData = {} as Record<string, never>;

function utcDay(value: Date): number {
  return Date.UTC(
    value.getUTCFullYear(),
    value.getUTCMonth(),
    value.getUTCDate(),
  );
}

function parseDate(value: string): Date {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error("Invalid candidate date");
  return date;
}

function deadlineWindow(
  deadline: Date,
  now: Date,
): {
  key: string;
  phrase: string;
} | null {
  const days = Math.round((utcDay(deadline) - utcDay(now)) / dayMs);
  if (days === 3) return { key: "3-days", phrase: "in 3 days" };
  if (days === 1) return { key: "1-day", phrase: "tomorrow" };
  if (days === 0) return { key: "today", phrase: "today" };
  return null;
}

/** Pure orchestration: the adapter owns database access and atomic insertion. */
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
  const preferenceCache = new Map<string, Promise<Preferences>>();
  const preferences = (userId: string) => {
    let value = preferenceCache.get(userId);
    if (!value) {
      value = store.getPreferences(userId);
      preferenceCache.set(userId, value);
    }
    return value;
  };
  const insert = async (notification: NotificationInsert) => {
    if (await store.insert(notification)) summary.created++;
    else summary.duplicates++;
  };

  for (let offset = 0; ; offset += pageSize) {
    const projects = await store.listProjects(offset, pageSize);
    for (const project of projects) {
      summary.projectsChecked++;
      if (!project.profile_exists) {
        summary.missingProfiles++;
        continue;
      }
      try {
        if (
          project.project_status !== "active" ||
          !project.end_date ||
          !(await preferences(project.user_id)).deadline_reminder_enabled
        )
          continue;
        const deadline = parseDate(project.end_date);
        const window = deadlineWindow(deadline, now);
        if (!window) continue;
        await insert({
          user_id: project.user_id,
          type: "DEADLINE_REMINDER",
          context_type: "PROJECT",
          project_id: project.project_id,
          board_id: null,
          task_id: null,
          title: "Project deadline approaching",
          message: `“${project.project_name}” is due ${window.phrase}.`,
          unique_key: `project-deadline:${project.project_id}:${project.end_date}:${window.key}`,
          action_data: emptyActionData,
        });
      } catch (_) {
        summary.failed++;
      }
    }
    if (projects.length < pageSize) break;
  }

  for (let offset = 0; ; offset += pageSize) {
    const tasks = await store.listTasks(offset, pageSize);
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
      )
        continue;
      let settings: Preferences;
      try {
        settings = await preferences(task.user_id);
      } catch (_) {
        summary.failed++;
        continue;
      }
      if (settings.stalled_task_enabled && task.last_activity_at) {
        try {
          const activity = parseDate(task.last_activity_at);
          if (now.getTime() - activity.getTime() >= stalledMs) {
            await insert({
              user_id: task.user_id,
              type: "STALLED_TASK",
              context_type: "TASK",
              project_id: task.project_id,
              board_id: task.board_id,
              task_id: task.task_id,
              title: "Task may be stalled",
              message: `“${task.task_title}” has not been updated for 7 days.`,
              unique_key: `stalled:${task.task_id}:${activity.toISOString()}`,
              action_data: emptyActionData,
            });
          }
        } catch (_) {
          summary.failed++;
        }
      }
      if (settings.deadline_reminder_enabled && task.deadline) {
        try {
          const deadline = parseDate(task.deadline);
          const window = deadlineWindow(deadline, now);
          if (window) {
            await insert({
              user_id: task.user_id,
              type: "DEADLINE_REMINDER",
              context_type: "TASK",
              project_id: task.project_id,
              board_id: task.board_id,
              task_id: task.task_id,
              title: "Task deadline approaching",
              message: `“${task.task_title}” is due ${window.phrase}.`,
              unique_key: `task-deadline:${task.task_id}:${deadline.toISOString()}:${window.key}`,
              action_data: emptyActionData,
            });
          }
        } catch (_) {
          summary.failed++;
        }
      }
    }
    if (tasks.length < pageSize) break;
  }
  return summary;
}
