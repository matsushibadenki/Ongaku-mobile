from pathlib import Path
import sys
root=Path(__file__).resolve().parent.parent
source=(root/'audio/AudioPlayerViewModel.swift').read_text()
template=(root/'tests/EffectEventsModel.swift').read_text()
a='    var effectsPresentationEvents: [AnyPublisher<Void, Never>]'
start=source.index(a); end=source.index('\n    }',start)+6
Path(sys.argv[1]).write_text(template.replace('    // SHIPPING_EVENTS',source[start:end]))
