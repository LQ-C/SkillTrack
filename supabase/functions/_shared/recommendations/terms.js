// Canonical phrases are deliberately independent of the synthetic evaluation data.
const ALIASES = [
  [/\breactjs\b|\breact\.js\b/g, "react"],
  [/\breactnative\b/g, "react native"],
  [/\bjs\b/g, "javascript"],
  [/\bts\b/g, "typescript"],
  [/\bpostgres\b/g, "postgresql"],
  [/\bpostgre sql\b/g, "postgresql"],
  [/\bnode\.js\b|\bnodejs\b/g, "node"],
  [/\bexpress\.js\b/g, "express"],
  [/(?<!\w)c\+\+(?!\w)/g, "cplusplus"],
  [/\bc#/g, "csharp"],
  [/\bui\b/g, "user interface"],
  [/\bauth\b/g, "authentication"],
  [/\bunit testing\b/g, "unit tests"],
  [/\bforms\b/g, "form"],
  [/\bvalidat(?:e|es|ed|ing)\b/g, "validation"],
  [/\bweb app(?:lication)?s?\b/g, "web development"],
  [/\bmobile app(?:lication)?s?\b/g, "mobile development"],
];

export function normalize(value) {
  let text = String(value ?? "").normalize("NFKC").toLowerCase();
  for (const [pattern, replacement] of ALIASES) {
    text = text.replace(pattern, replacement);
  }
  return text.replace(/[^\p{L}\p{N}]+/gu, " ").trim().replace(/\s+/g, " ");
}

const KEYWORD_PHRASES = `
flutter,react native,react,angular,vue,dart,javascript,typescript,python,java,php,go,cplusplus,csharp,
html,css,flexbox,grid,widget layout,row,column,expanded,container,gridview,listview,listview builder,
itemcount,itembuilder,textfield,textformfield,validator,navigator pushnamed,named routes,futurebuilder,
http get,jsondecode,sqflite,sharedpreferences,supabase,supabase flutter,signinwithpassword,
firebase,firestore,api,rest,fetch,useeffect,usestate,props,hooks,react router,react navigation,
dom,addeventlistener,queryselector,localstorage,sessionstorage,express,node,mongodb,mysql,
postgresql,sqlite,sql server,django,flask,laravel,eloquent,spring boot,jpa,asp net,
get routes,post validation,route params,json,form,validation,form validation,authentication,crud,
select,insert,update,delete,join,group by,order by,foreign keys,create table,
git,branching,merge,gitignore,postman,pytest,unit tests,interfaces,inheritance,
async,await,async await,try catch,exception handling,vector,sort,scanf,uml,
http handlers,encoding json,model binding,controller,repository,middleware
`.split(",").map(normalize).filter(Boolean);

const KEYWORD_SET = [...new Set(KEYWORD_PHRASES)];

// Generated project tasks often name the product feature instead of an API.
// These focused concepts are extracted from both tasks and resource content.
// The second value is a related technical concept where the feature implies one.
export const FEATURE_RULES = [
  [
    "registration",
    /\b(registration|register users?|sign ?up|create (an? )?account)\b/,
    "form validation",
  ],
  [
    "menu management",
    /\b(menu management|manag(e|ing) (the )?menu|menu items?|restaurant menu|food menu)\b/,
  ],
  [
    "restaurant discovery",
    /\b(restaurant discovery|discover restaurants?|browse restaurants?|find restaurants?|search restaurants?|restaurant search)\b/,
  ],
];

const GENERAL_KEYWORDS = new Set(
  `flutter,react native,react,angular,vue,dart,javascript,typescript,
  python,java,php,go,cplusplus,csharp,html,css,supabase,firebase,express,node,django,flask,
  laravel,spring boot,asp net,api,rest,widget layout`.split(",").map(normalize),
);

export function extractFeatureKeywords(...parts) {
  const text = normalize(parts.filter(Boolean).join(" "));
  return FEATURE_RULES.filter(([, pattern]) => pattern.test(text))
    .map(([term]) => term).sort();
}

export function hasSpecificKeywordOverlap(queryKeywords, resourceKeywords) {
  const right = new Set(resourceKeywords);
  return queryKeywords.some((term) =>
    !GENERAL_KEYWORDS.has(term) && right.has(term)
  );
}

export function hasConflictingFeature(queryFeatures, resourceKeywords) {
  return FEATURE_RULES.some(([feature]) =>
    resourceKeywords.includes(feature) &&
    !queryFeatures.includes(feature)
  );
}

// Broad, stable subjects. A phrase may produce several tags, for example Flutter
// maps to both the platform and framework. The same rules apply to tasks/resources.
export const TOPIC_RULES = [
  [
    "mobile development",
    /\b(mobile development|flutter|dart|react native|android|ios)\b/,
  ],
  [
    "web development",
    /\b(web development|html|css|javascript|typescript|react|vue|angular|django|flask|express|laravel|spring boot|asp net)\b/,
  ],
  [
    "frontend development",
    /\b(frontend|html|css|react|vue|angular|dom|user interface)\b/,
  ],
  [
    "backend development",
    /\b(backend|express|django|flask|laravel|spring boot|asp net|http handlers)\b/,
  ],
  [
    "user interface layout",
    /\b(layout|row|column|expanded|flexbox|grid|widget|styling|box model)\b/,
  ],
  ["user interface design", /\b(screen|interface|view|user interface|page)\b/],
  [
    "forms and validation",
    /\b(form|textfield|validator|validation|input|registration|register|sign up)\b/,
  ],
  [
    "content management",
    /\b(menu management|manage menu|menu items|restaurant menu)\b/,
  ],
  [
    "search and discovery",
    /\b(discovery|discover|browse restaurants|find restaurants|search restaurants|restaurant search)\b/,
  ],
  [
    "navigation and routing",
    /\b(navigation|navigator|routing|routes|route params)\b/,
  ],
  ["api integration", /\b(api|rest|http|json|fetch|postman)\b/],
  ["state management", /\b(state|hooks|usestate|useeffect|props)\b/],
  ["authentication", /\b(authentication|login|signin|password)\b/],
  [
    "database",
    /\b(database|sqlite|sql|postgresql|mysql|mongodb|firestore|supabase|crud|jpa|eloquent)\b/,
  ],
  ["testing", /\b(test|testing|pytest|assertions|fixtures)\b/],
  ["version control", /\b(git|branching|merge|commit|repository hygiene)\b/],
  [
    "object oriented programming",
    /\b(class|classes|inheritance|interface|encapsulation|properties)\b/,
  ],
  [
    "general programming",
    /\b(general programming|functions|arrays|loops|vectors|sorting)\b/,
  ],
  [
    "software design",
    /\b(software engineering|uml|use case|diagrams|design)\b/,
  ],
];

export function extractKeywords(...parts) {
  const text = normalize(parts.filter(Boolean).join(" "));
  if (!text) return [];
  const padded = ` ${text} `;
  const terms = KEYWORD_SET.filter((term) => padded.includes(` ${term} `));
  for (const [feature, pattern, implied] of FEATURE_RULES) {
    if (pattern.test(text)) terms.push(feature, ...(implied ? [implied] : []));
  }
  return [...new Set(terms)].sort();
}

export function extractTopicTags(...parts) {
  const text = normalize(parts.filter(Boolean).join(" "));
  return TOPIC_RULES.filter(([, pattern]) => pattern.test(text)).map(([tag]) =>
    tag
  ).sort();
}

export function normalizeKeywords(value) {
  const entries = Array.isArray(value) ? value : String(value ?? "").split(",");
  const normalized = entries.map(normalize).filter(Boolean);
  return [...new Set([...normalized, ...extractKeywords(...normalized)])]
    .sort();
}

export function normalizeTopicTags(value) {
  const entries = Array.isArray(value) ? value : String(value ?? "").split(",");
  return extractTopicTags(...entries);
}
