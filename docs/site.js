const revealed = document.querySelectorAll(".reveal");
const yearNodes = document.querySelectorAll("[data-current-year]");
const carousels = document.querySelectorAll("[data-carousel]");
const topbars = document.querySelectorAll(".topbar");

for (const node of yearNodes) {
  node.textContent = String(new Date().getFullYear());
}

for (const topbar of topbars) {
  const toggle = topbar.querySelector(".menu-toggle");
  const nav = topbar.querySelector(".nav-links");

  if (!toggle || !nav) {
    continue;
  }

  const closeMenu = () => {
    topbar.classList.remove("is-open");
    toggle.setAttribute("aria-expanded", "false");
    toggle.setAttribute("aria-label", "Open menu");
  };

  toggle.addEventListener("click", () => {
    const isOpen = topbar.classList.toggle("is-open");
    toggle.setAttribute("aria-expanded", String(isOpen));
    toggle.setAttribute("aria-label", isOpen ? "Close menu" : "Open menu");
  });

  nav.querySelectorAll("a").forEach((link) => {
    link.addEventListener("click", closeMenu);
  });

  window.matchMedia("(min-width: 761px)").addEventListener("change", (event) => {
    if (event.matches) {
      closeMenu();
    }
  });
}

if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      }
    },
    {
      threshold: 0.16,
      rootMargin: "0px 0px -8% 0px"
    }
  );

  for (const element of revealed) {
    observer.observe(element);
  }
} else {
  for (const element of revealed) {
    element.classList.add("is-visible");
  }
}

for (const carousel of carousels) {
  const slides = Array.from(carousel.querySelectorAll(".tutorial-carousel-slide"));
  const dots = Array.from(carousel.querySelectorAll("[data-carousel-dot]"));
  const previousButton = carousel.querySelector("[data-carousel-prev]");
  const nextButton = carousel.querySelector("[data-carousel-next]");

  if (slides.length === 0) {
    continue;
  }

  let activeIndex = slides.findIndex((slide) => slide.classList.contains("is-active"));
  if (activeIndex < 0) {
    activeIndex = 0;
  }

  const renderCarousel = () => {
    slides.forEach((slide, index) => {
      slide.classList.toggle("is-active", index === activeIndex);
    });

    dots.forEach((dot, index) => {
      const isActive = index === activeIndex;
      dot.classList.toggle("is-active", isActive);
      if (isActive) {
        dot.setAttribute("aria-current", "true");
      } else {
        dot.removeAttribute("aria-current");
      }
    });
  };

  previousButton?.addEventListener("click", () => {
    activeIndex = (activeIndex - 1 + slides.length) % slides.length;
    renderCarousel();
  });

  nextButton?.addEventListener("click", () => {
    activeIndex = (activeIndex + 1) % slides.length;
    renderCarousel();
  });

  dots.forEach((dot, index) => {
    dot.addEventListener("click", () => {
      activeIndex = index;
      renderCarousel();
    });
  });

  renderCarousel();
}
