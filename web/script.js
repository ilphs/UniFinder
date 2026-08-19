(function () {
  var STORAGE_KEY = "unifinder-lang";

  function applyLang(lang) {
    document.documentElement.lang = lang === "en" ? "en" : "ko";

    document.querySelectorAll("[data-ko][data-en]").forEach(function (el) {
      el.textContent = lang === "en" ? el.dataset.en : el.dataset.ko;
    });

    document.querySelectorAll(".lang-btn").forEach(function (btn) {
      btn.classList.toggle("is-active", btn.dataset.lang === lang);
    });
  }

  function currentLang() {
    return localStorage.getItem(STORAGE_KEY) || "ko";
  }

  document.querySelectorAll(".lang-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var lang = btn.dataset.lang;
      localStorage.setItem(STORAGE_KEY, lang);
      applyLang(lang);
    });
  });

  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var text = btn.dataset.copy;
      navigator.clipboard.writeText(text).then(function () {
        var lang = currentLang();
        var original = lang === "en" ? btn.dataset.en : btn.dataset.ko;
        btn.textContent = lang === "en" ? "Copied" : "복사됨";
        setTimeout(function () {
          btn.textContent = original;
        }, 1500);
      });
    });
  });

  applyLang(currentLang());
})();
