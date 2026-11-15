struct Item {
    let name: String
    let price: Double
    let quantity: Int
}

struct Cart {
    var items: [Item] = []
    var discountPercent: Double = 0

    mutating func add(_ item: Item) {
        items.append(item)
    }

    func subtotal() -> Double {
        var total = 0.0
        for item in items {
            let line = item.price * Double(item.quantity)
            total += line
        }
        return total
    }

    func total() -> Double {
        let sub = subtotal()
        let discount = sub * (discountPercent / 100)
        return sub - discount
    }
}

var cart = Cart()
cart.add(Item(name: "Coffee", price: 4.50, quantity: 2))
cart.add(Item(name: "Bagel", price: 3.25, quantity: 1))
cart.add(Item(name: "Juice", price: 5.00, quantity: 3))
cart.discountPercent = 10

let result = cart.total()
print("Total: \(result)")
