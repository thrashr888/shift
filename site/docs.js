// On a narrow screen the rail of every page starts closed; on a wide one it stays open and inert.
(() => {
  const rail = document.querySelector('details.rail');
  if (rail && matchMedia('(max-width: 900px)').matches) rail.open = false;
})();
