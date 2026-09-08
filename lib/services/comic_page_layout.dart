/// Maps physical scroll offsets to a stable page index plus a page fraction.
/// Image dimensions can arrive later, and device rotation can change every
/// page's height, without changing the reader's logical position.
class ComicPageLayout {
  final List<double> _starts;

  ComicPageLayout(Iterable<double> heights) : _starts = _pageStarts(heights);

  static List<double> _pageStarts(Iterable<double> heights) {
    final starts = <double>[0];
    for (final height in heights) {
      if (!height.isFinite || height <= 0) {
        throw ArgumentError.value(
          height,
          'height',
          'Must be finite and positive',
        );
      }
      starts.add(starts.last + height);
    }
    return starts;
  }

  int get pageCount => _starts.length - 1;
  double get totalHeight => _starts.last;

  double heightAt(int index) => _starts[index + 1] - _starts[index];

  double positionAtOffset(double offset) {
    if (pageCount == 0 || !offset.isFinite || offset <= 0) return 0;
    if (offset >= totalHeight) return pageCount.toDouble();
    var low = 0;
    var high = pageCount;
    while (low + 1 < high) {
      final middle = low + (high - low) ~/ 2;
      if (_starts[middle] <= offset) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low + (offset - _starts[low]) / heightAt(low);
  }

  double offsetForPosition(double position) {
    if (pageCount == 0 || !position.isFinite || position <= 0) return 0;
    if (position >= pageCount) return totalHeight;
    final page = position.floor();
    return _starts[page] + (position - page) * heightAt(page);
  }
}
