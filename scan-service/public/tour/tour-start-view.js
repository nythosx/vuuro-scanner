(function () {
  'use strict';

  function pickStartView(view, embed, flags) {
    var f = flags || {};
    if (view === 'dollhouse') {
      return f.hasDollhouse ? 'dollhouse' : 'plan';
    }
    if (view === 'walkthrough') {
      return (f.walkthrough === true && f.hasStand === true) ? 'walkthrough' : 'plan';
    }
    if (view === 'photos') {
      return f.hasPhotos ? 'photos' : 'plan';
    }
    if (view === 'plan') {
      return 'plan';
    }
    if (embed === true) {
      if (f.walkthrough === true && f.hasStand === true) {
        return 'walkthrough';
      }
      if (f.hasDollhouse) {
        return 'dollhouse';
      }
      if (f.hasPhotos) {
        return 'photos';
      }
    }
    return 'plan';
  }

  window.TourStartView = { pick: pickStartView };
})();
