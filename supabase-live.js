(function () {
  const client = window.tzCreateClient ? window.tzCreateClient() : null;
  if (!client) return;

  const locale = () => (document.documentElement.getAttribute("data-locale") === "zh" ? "zh" : "en");
  let contentRows = [];
  let newsRows = [];

  function applyContent() {
    contentRows.forEach((row) => {
      const value = locale() === "zh" ? row.value_zh : row.value_en;
      if (!value) return;
      document.querySelectorAll('[data-content="' + row.key + '"]').forEach((el) => {
        el.textContent = value;
      });
    });
  }

  function renderNews() {
    const list = document.getElementById("news-list");
    const section = document.getElementById("news");
    if (!list || !section) return;
    const visible = newsRows.filter((row) => row.published);
    section.hidden = false;
    if (!visible.length) {
      list.replaceChildren();
      const empty = document.createElement("p");
      empty.className = "news-empty";
      empty.id = "news-empty";
      const zh = document.createElement("span");
      zh.className = "zh";
      zh.textContent = "目前還沒有最新消息。";
      const en = document.createElement("span");
      en.className = "en";
      en.textContent = "There is no news yet.";
      empty.append(zh, en);
      list.append(empty);
      return;
    }
    list.replaceChildren();
    visible.forEach((row) => {
      const article = document.createElement("article");
      article.className = "news-card";
      const title = document.createElement("h3");
      title.textContent = locale() === "zh" ? row.title_zh : row.title_en;
      const body = document.createElement("p");
      body.textContent = locale() === "zh" ? row.body_zh : row.body_en;
      article.append(title, body);
      list.append(article);
    });
  }

  function refreshContent() {
    client.from("site_content").select("key,value_zh,value_en").then(({ data }) => {
      contentRows = data || [];
      applyContent();
    });
  }

  function refreshNews() {
    client
      .from("news")
      .select("title_zh,title_en,body_zh,body_en,published,created_at")
      .eq("published", true)
      .order("created_at", { ascending: false })
      .then(({ data }) => {
        newsRows = data || [];
        renderNews();
      });
  }

  refreshContent();
  refreshNews();
  client
    .channel("tz-home")
    .on("postgres_changes", { event: "*", schema: "public", table: "site_content" }, refreshContent)
    .on("postgres_changes", { event: "*", schema: "public", table: "news" }, refreshNews)
    .subscribe();
  document.addEventListener("tzuspark-locale", () => {
    applyContent();
    renderNews();
  });

  client.auth.getSession().then(({ data }) => {
    const link = document.getElementById("account-link");
    if (!data.session || !link) return;
    const zh = link.querySelector(".zh");
    const en = link.querySelector(".en");
    if (zh) zh.textContent = "後台";
    if (en) en.textContent = "Back office";
  });

  trackVisit();

  function trackVisit() {
    const cfg = window.TZUSPARK_SUPABASE || {};
    if (!cfg.url || !cfg.anonKey) return;
    const makeId = () => (window.crypto && crypto.randomUUID ? crypto.randomUUID() : "v-" + Date.now().toString(36) + Math.random().toString(36).slice(2, 10));
    let visitorId = "";
    let sessionId = "";
    try { visitorId = localStorage.getItem("tzuspark-visitor-id") || ""; } catch (err) { visitorId = ""; }
    if (!visitorId) {
      visitorId = makeId();
      try { localStorage.setItem("tzuspark-visitor-id", visitorId); } catch (err) {}
    }
    try { sessionId = sessionStorage.getItem("tzuspark-session-id") || ""; } catch (err) { sessionId = ""; }
    if (!sessionId) {
      sessionId = makeId();
      try { sessionStorage.setItem("tzuspark-session-id", sessionId); } catch (err) {}
    }
    function send(row) {
      const section = location.hash || "#home";
      fetch(cfg.url.replace(/\/$/, "") + "/rest/v1/site_events", {
        method: "POST",
        headers: {
          apikey: cfg.anonKey,
          Authorization: "Bearer " + cfg.anonKey,
          "Content-Type": "application/json",
          Prefer: "return=minimal"
        },
        body: JSON.stringify({
          visitor_id: visitorId,
          session_id: sessionId,
          event_type: row.event_type,
          path: (row.path || section).slice(0, 200),
          label: row.label ? String(row.label).slice(0, 160) : null,
          href: row.href ? String(row.href).slice(0, 300) : null,
          duration_seconds: row.duration_seconds == null ? null : row.duration_seconds
        }),
        keepalive: true
      }).catch(() => {});
    }
    const heading = document.querySelector("h1");
    const pageLabel = heading && heading.textContent ? heading.textContent.replace(/\s+/g, " ").trim() : document.title;
    send({ event_type: "pageview", label: pageLabel, path: location.hash || "#home" });
    window.addEventListener("hashchange", () => {
      send({ event_type: "pageview", label: location.hash || "#home", path: location.hash || "#home" });
    });
    let lastTick = Date.now();
    let sentSeconds = 0;
    function flushDuration() {
      const now = Date.now();
      let delta = Math.round((now - lastTick) / 1000);
      lastTick = now;
      if (delta < 1) return;
      if (delta > 90) delta = 90;
      if (sentSeconds >= 1800) return;
      sentSeconds += delta;
      send({ event_type: "duration", duration_seconds: delta, label: pageLabel, path: location.hash || "#home" });
    }
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") flushDuration();
      else lastTick = Date.now();
    });
    window.addEventListener("pagehide", flushDuration);
    setInterval(() => {
      if (document.visibilityState === "visible") flushDuration();
    }, 30000);
    document.addEventListener("click", (event) => {
      const link = event.target.closest ? event.target.closest("a[href]") : null;
      if (!link) return;
      const href = link.getAttribute("href") || "";
      if (!href || href.indexOf("javascript:") === 0) return;
      const label = (link.innerText || link.getAttribute("aria-label") || href).replace(/\s+/g, " ").trim();
      send({ event_type: "click", label: label, href: href, path: href.charAt(0) === "#" ? href : (location.hash || "#home") });
    });
  }

  const form = document.getElementById("contact-form");
  if (!form) return;
  form.addEventListener("submit", async () => {
    const session = (await client.auth.getSession()).data.session;
    if (!session) return;
    const data = new FormData(form);
    const { error } = await client.from("messages").insert({
      user_id: session.user.id,
      kind: "message",
      name: String(data.get("name") || ""),
      email: String(data.get("email") || ""),
      topic: String(data.get("topic") || ""),
      body: String(data.get("message") || "")
    });
    const thanks = document.getElementById("thanks");
    if (!thanks) return;
    const title = thanks.querySelector("h3");
    const note = thanks.querySelector("p");
    const isZh = locale() === "zh";
    if (error) {
      if (title) title.textContent = isZh ? "這則還沒送到資料庫。" : "This note was not saved.";
      if (note) note.textContent = error.message;
      return;
    }
    if (title) title.textContent = isZh ? "已送到 TzuSpark。" : "Sent to TzuSpark.";
    if (note) note.textContent = isZh ? "這則訊息已經寫進資料庫，後台可以立刻看到。" : "This message is in the database, and the back office can see it right away.";
  }, true);
})();
