# Payload Card Reader iOS Library

An iOS library for integrating [Payload](https://payload.co)

## Installation

### Cocoapod Installation

- Add `pod 'PayloadCardReader'` to your Podfile

- Run `pod install`

## Get Started

Once you've included the Payload iOS library into you project,
import the library into your view.

```swift
import PayloadAPI
import PayloadCardReader
````

### API Authentication

To authenticate with the Payload API, you'll need a live or test API key. API
keys are accessible from within the Payload dashbvoard.

```swift
import PayloadAPI

Payload.api_key = "client_key_3bW9JMZtPVDOfFNzwRdfE"
```

## Connect to a Device

Use `PayloadDeviceManagerDelegate` to watch for device events.

```swift
import PayloadAPI
import PayloadCardReader

class ViewController: UIViewController, PayloadCardReaderManagerDelegate {
    var manager:Payload.CardReader.Manager!;

    override func viewDidLoad() {
        super.viewDidLoad()
        self.manager = Payload.CardReader.Manager(self);
        self.manager.monitor()
    }

    func detected(_ reader:Payload.CardReader){
        if ( self.manager.connectedCardReader() == nil ) {
            reader.connect();
        }
    }

    func connected(_ reader:Payload.CardReader) { /* handle event */ }
    func disconnected(_ reader: Payload.CardReader) { /* handle event */ }
    func connectionError(_ reader:Payload.CardReader, _ error:Payload.CardReader.Error) { /* handle event */ }

}
```

## Processing a Payment

To initiate a payment request,  call  `Checkout` with a Payload Payment object once a reader has been connected.

```swift
do {
    try Payload.Checkout(Payload.Payment(
        amount: 10,
        processing_id: "acct_3bfCMwa8OwUbYOvUQKTGi"
    ), delegate: self )
} catch let error as Payload.Errors.TransactionAlreadyStarted {
    print(error.message)
}
```



## Documentation

To get further information on Payload's iOS library and API capabilities,
visit the unabridged [Payload Documentation](https://docs.payload.co/card-readers).
